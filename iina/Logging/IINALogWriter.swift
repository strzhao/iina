//
//  IINALogWriter.swift
//  iina
//
//  JSONL 文件 IO + 轮转 + 保留清理（单职责，从 Logger 拆出）。
//
//  对齐兄弟项目 claude-code-buddy 的 LogWriter 设计。
//

import Foundation

/// JSONL 文件 IO + 轮转 + 保留清理（单职责）。
///
/// 设计契约：
/// - 容错：任何 IO 失败静默降级（关闭句柄、下次重试），绝不抛出 / 绝不崩溃 / 绝不阻塞调用方超过单行 append 耗时。
/// - 新鲜度：以 append 模式打开当前文件，跨重启不覆盖。
/// - flush：每行 write 后立即 `synchronize()` 落盘（解决既有 `Logger.log` 经 `print` 到 stdout 的 buffer 问题，
///   崩溃后日志仍可见——这是 CLI 取阅 / 线上排查最关键的保证）。
///
/// 线程安全：由 `Logger` 通过串行 `DispatchQueue`（`jsonlQueue`）保护，本类自身不做同步，
/// 所有方法必须在调用方的串行上下文中调用。
final class IINALogWriter {

  private var fileHandle: FileHandle?
  private var currentSize: Int = 0
  private let logsDir: String
  private let currentPath: String
  private let isoFormatter: ISO8601DateFormatter

  init(logsDir: String = IINALogConfig.logsDir,
       currentPath: String = IINALogConfig.currentLogPath) {
    self.logsDir = logsDir
    self.currentPath = currentPath
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.isoFormatter = formatter
  }

  // MARK: - 初始化（首次启动）

  /// 确保日志目录与当前文件存在（append 模式，跨重启不覆盖）。失败静默降级。
  func ensureCurrentFile() {
    let fm = FileManager.default
    do {
      try fm.createDirectory(
        atPath: logsDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: IINALogConfig.dirPermissions)]
      )
      // createDirectory 在目录已存在时不会改权限，补一道 chmod 确保契约
      try? fm.setAttributes([.posixPermissions: NSNumber(value: IINALogConfig.dirPermissions)], ofItemAtPath: logsDir)
    } catch {
      // 目录创建失败：静默降级，写入时会再失败再降级
      return
    }
    if !fm.fileExists(atPath: currentPath) {
      // 新建空文件（权限 0600）
      fm.createFile(atPath: currentPath, contents: nil, attributes: [
        .posixPermissions: NSNumber(value: IINALogConfig.filePermissions)
      ])
    }
    openHandle()
  }

  private func openHandle() {
    guard fileHandle == nil else { return }
    do {
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: currentPath))
      // append 模式：seekToEnd（跨重启追加，不覆盖）
      try handle.seekToEnd()
      currentSize = try Int(handle.offset())
      fileHandle = handle
    } catch {
      fileHandle = nil
      currentSize = 0
    }
  }

  // MARK: - 写入

  /// 编码一行 JSONL 并 append。返回是否实际写入（级别过滤已由调用方 Logger 完成）。
  ///
  /// - Parameters:
  ///   - level: 日志级别（写入 JSONL 的 `level` 字段用其 `description`，如 "warning"）。
  ///   - subsystem: 子系统名（写入 `subsystem` 字段）。
  ///   - msg: 日志消息。
  ///   - meta: 可选结构化键值对（写入 `meta` 字段）；调用方负责脱敏。
  ///   - file: 可选源文件路径（写入 `meta.file`，定位辅助）。
  ///   - line: 可选源行号（写入 `meta.line`，定位辅助）。
  func append(level: Logger.Level, subsystem: String, msg: String,
              meta: [String: Any]?, file: String?, line: Int?) {
    ensureCurrentFileOpen()
    guard let handle = fileHandle else { return }

    let payload = encodePayload(
      level: level, subsystem: subsystem, msg: msg, meta: meta, file: file, line: line
    )
    guard let data = encodeLine(payload) else { return }

    // 写前检查轮转（currentSize + data.count > 阈值）
    if currentSize + data.count > IINALogConfig.rotateSizeBytes {
      rotate(handle: handle)
      // 轮转后 fileHandle 已替换，重新取
      guard let newHandle = fileHandle else { return }
      writeLine(newHandle, data: data)
    } else {
      writeLine(handle, data: data)
    }
  }

  private func ensureCurrentFileOpen() {
    if fileHandle == nil {
      ensureCurrentFile()
    }
  }

  private func encodePayload(level: Logger.Level, subsystem: String, msg: String,
                             meta: [String: Any]?, file: String?, line: Int?) -> [String: Any] {
    var payload: [String: Any] = [
      IINALogConfig.fieldTimestamp: isoFormatter.string(from: Date()),
      IINALogConfig.fieldLevel: level.description,   // "verbose"/"debug"/"warning"/"error"
      IINALogConfig.fieldSubsystem: subsystem,
      IINALogConfig.fieldMessage: msg
    ]
    // file/line 作为定位辅助，并入 meta（不污染顶层 5 字段 schema，与 CLI 解析兼容）
    if file != nil || line != nil {
      var extended = meta ?? [:]
      if let file = file { extended["file"] = (file as NSString).lastPathComponent }
      if let line = line { extended["line"] = line }
      payload[IINALogConfig.fieldMeta] = extended
    } else if let meta = meta, !meta.isEmpty {
      payload[IINALogConfig.fieldMeta] = meta
    }
    return payload
  }

  /// JSONSerialization 编码 + 追加 `\n`。失败返回 nil（容错）。
  private func encodeLine(_ payload: [String: Any]) -> Data? {
    do {
      let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]   // 稳定字段顺序：level/msg/subsystem/ts（+meta）
      )
      // 追加换行（JSON Lines：每行一个 JSON 对象 + \n）
      guard var line = String(data: data, encoding: .utf8) else { return nil }
      line += "\n"
      return line.data(using: .utf8)
    } catch {
      return nil
    }
  }

  private func writeLine(_ handle: FileHandle, data: Data) {
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()   // 立即落盘（崩溃排查最关键）
      currentSize += data.count
    } catch {
      // 写失败：关闭句柄，下次重试（容错：静默降级）
      closeHandle()
    }
  }

  // MARK: - 轮转（契约 C1）

  /// 当前文件 > 5 MiB → close → rename `iina-<ts>.jsonl` → reopen 新 `iina.jsonl`。
  private func rotate(handle: FileHandle) {
    closeHandle()

    let timestamp = archiveTimestamp()
    let archivePath = "\(logsDir)/iina-\(timestamp).jsonl"
    let fm = FileManager.default

    // rename（永不覆盖：归档命名含时间戳，同秒内多次轮转才可能撞名，用 try? 兜底）
    do {
      try fm.moveItem(atPath: currentPath, toPath: archivePath)
    } catch {
      // move 失败（如目标已存在 / 源不存在）：尝试删除当前文件强制新建
      try? fm.removeItem(atPath: currentPath)
    }

    // 新建当前文件
    fm.createFile(atPath: currentPath, contents: nil, attributes: [
      .posixPermissions: NSNumber(value: IINALogConfig.filePermissions)
    ])
    openHandle()

    // 轮转后清理超额归档
    pruneArchives()
  }

  /// 归档时间戳 `YYYYMMDD-HHMMSS`（UTC）。
  private func archiveTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
  }

  // MARK: - 保留清理（契约 C1：目录总占用 > 50 MiB 或归档 > 30 个 → 删除最旧归档）

  func pruneArchives() {
    let fm = FileManager.default
    let archiveURLs: [URL]
    do {
      archiveURLs = try fm.contentsOfDirectory(
        at: URL(fileURLWithPath: logsDir),
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
      ).filter { $0.lastPathComponent.hasPrefix("iina-") && $0.pathExtension == "jsonl" }
    } catch {
      return
    }

    guard !archiveURLs.isEmpty else { return }

    // 按修改时间升序（最旧在前）
    var sorted = archiveURLs.sorted { lhs, rhs in
      let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return l < r
    }

    // 计算归档总大小
    func totalSize(_ urls: [URL]) -> Int {
      urls.reduce(0) { acc, url in
        acc + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    }

    // 删除最旧归档直到满足两个约束：归档数 <= retainMaxArchives 且 总大小 <= retainTotalSizeBytes
    while !sorted.isEmpty &&
            (sorted.count > IINALogConfig.retainMaxArchives ||
              totalSize(sorted) > IINALogConfig.retainTotalSizeBytes) {
      let oldest = sorted.removeFirst()
      try? fm.removeItem(at: oldest)
    }
  }

  // MARK: - 清理句柄

  private func closeHandle() {
    try? fileHandle?.close()
    fileHandle = nil
    currentSize = 0
  }

  /// 关闭句柄（app 退出时调用）。
  func close() {
    closeHandle()
  }

  // MARK: - 仅测试用查询

  /// 仅供测试：当前是否已打开文件句柄。
  var hasOpenHandle: Bool { fileHandle != nil }

  /// 仅供测试：当前文件累计写入字节数。
  var _currentSize: Int { currentSize }
}
