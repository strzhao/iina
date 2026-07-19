//
//  IINALogConfig.swift
//  iina
//
//  JSONL 日志系统配置（SOURCE OF TRUTH）。
//
//  对齐兄弟项目 claude-code-buddy 的 LogConfig 设计，字段名保持一致以便复用 CLI 解析逻辑。
//
//  契约：
//  - 路径三常量 + 级别字符串集合 + 行 schema 字段名在此定义。
//  - CLI 侧（iina-cli/main.swift 的诊断子命令）必须 mirror，契约变更须同步（⚠️ MIRROR）。
//

import Foundation

/// IINA JSONL 日志系统配置（SOURCE OF TRUTH）。
///
/// 定义 `iina.jsonl`（结构化日志通道，独立于既有 `iina.log`）的路径、轮转边界、权限、
/// 行 schema 字段名，以及最小级别解析逻辑。
struct IINALogConfig {

  // MARK: - 路径常量（SOURCE OF TRUTH，契约 C1/C5）

  /// JSONL 日志目录：`~/Library/Logs/IINA`（固定路径，CLI 友好；Console.app 也识别）。
  ///
  /// 优先级：`IINA_LOG_DIR` 环境变量（测试隔离 / 自定义）> `~/Library/Logs/IINA`。
  /// CLI 侧（iina-cli）也必须识别 `IINA_LOG_DIR`，否则测试隔离下 app 写重定向目录、CLI 读默认目录，
  /// CLI 读不到 app 的日志。
  static var logsDir: String {
    if let env = ProcessInfo.processInfo.environment["IINA_LOG_DIR"], !env.isEmpty {
      return env
    }
    // 对齐 IINA 既有 Logger.logDirectory 的取 library 路径模式
    if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
      return libraryURL.appendingPathComponent("Logs").appendingPathComponent("IINA").path
    }
    return "\(NSHomeDirectory())/Library/Logs/IINA"
  }

  /// 当前日志文件名（永不带时间戳；轮转后归档为 `iina-<ts>.jsonl`）。
  static let currentLogFileName = "iina.jsonl"

  /// 当前日志文件绝对路径。
  static var currentLogPath: String {
    "\(logsDir)/\(currentLogFileName)"
  }

  // MARK: - 轮转 / 保留边界值（契约 C1）

  /// 当前文件 > 此阈值时 rename → `iina-<ts>.jsonl` 并新建当前文件。
  static let rotateSizeBytes: Int = 5 * 1024 * 1024   // 5 MiB

  /// 目录总占用 > 此阈值时删除最旧归档。
  static let retainTotalSizeBytes: Int = 50 * 1024 * 1024   // 50 MiB

  /// 归档数 > 此阈值时删除最旧归档。
  static let retainMaxArchives: Int = 30

  // MARK: - 文件权限（契约 C1）

  /// 目录权限 0700（owner rwx）。
  static let dirPermissions: UInt = 0o700

  /// 文件权限 0600（owner rw）——仅用户可读，保护日志隐私。
  static let filePermissions: UInt = 0o600

  // MARK: - 行 schema 字段名（契约 C1/C5，CLI 解析须同构）

  static let fieldTimestamp = "ts"
  static let fieldLevel = "level"
  static let fieldSubsystem = "subsystem"
  static let fieldMessage = "msg"
  static let fieldMeta = "meta"

  // MARK: - 环境变量 + 级别解析（契约 C2）

  /// 是否运行在 XCTest 宿主中（避免测试间日志相互污染）。
  static var isRunningTests: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// 解析最小级别（`iina.jsonl` 通道）。
  ///
  /// 优先级：
  /// 1. `IINA_LOG_LEVEL` 环境变量（`off|verbose|debug|info|warn|warning|error`）—— 一律覆盖
  /// 2. `#if DEBUG` → `debug` / release → `warning`（默认开，便于线上排查）
  /// 3. XCTest 宿主 → nil（关闭）
  ///
  /// - Important: IINA 的 `Logger.Level` 无 `info`（只有 verbose/debug/warning/error）。
  ///   `info`/`warn` env 值映射到 `warning`（兼容 buddy 用户的 `info` 习惯）。
  /// - Returns: 最小级别；nil 表示完全关闭 JSONL 日志。
  static func resolveMinLevel() -> Logger.Level? {
    if let env = ProcessInfo.processInfo.environment["IINA_LOG_LEVEL"] {
      switch env.lowercased() {
      case "off": return nil
      case "verbose": return .verbose
      case "debug": return .debug
      case "info", "warn", "warning": return .warning   // IINA 无 info，映射到 warning
      case "error": return .error
      default:
        break   // 未知值忽略，落到默认逻辑（不崩）
      }
    }
    if isRunningTests { return nil }
    #if DEBUG
    return .debug
    #else
    return .warning
    #endif
  }
}
