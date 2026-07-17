//
//  MediaLibraryDarkMode.acceptance.test.swift
//  iina
//
//  红队验收测试 — 暗黑模式视觉谓词 human-obs 占位（黑盒视角，## 验收场景 场景4）
//
//  覆盖谓词：
//    [human-obs 占位] darkmode.placeholder-visible-in-dark
//    [human-obs 占位] darkmode.failure-state-visible-in-dark
//    [human-obs 占位] darkmode.progress-text-readable-in-dark
//
//  注：darkmode.no-hardcoded-light-hex [det-machine/fs-grep] 在
//  MediaLibraryPerfReuseStatic.acceptance.test.swift 中覆盖（静态 hex 扫描）。
//
//  策略：暗黑模式视觉谓词无法纯 XCTest 自动化（需 GUI 截图 + 人眼）。
//  为每个写 XCTSkip 占位测试方法，方法名对齐谓词 id，doc 注释写清
//  「QA 阶段用 CGWindowList 截图 + 人眼验证」+ 具体 assert。
//  这样谓词有测试占位 + 清晰人工验证指引，不被遗忘。
//
//  红队声明：本测试从 ## 验收场景 独立编写，未读 iina/MediaLibrary/ 源码。
//

import XCTest
@testable import IINA

final class MediaLibraryDarkModeAcceptanceTests: XCTestCase {

  // MARK: - darkmode.placeholder-visible-in-dark [human-obs]
  // 暗黑模式 + 缩略图待生成 → spinner 在深色背景下仍可见

  /// 谓词: darkmode.placeholder-visible-in-dark
  /// QA 阶段：暗黑模式截图，待生成卡片封面区。
  /// 驱动：`defaults write -g AppleInterfaceStyle Dark` → open IINA.app →
  ///        媒体库扫描中（缩略图待生成态）→ CGWindowList 截图 darkmode_loading.png。
  /// assert: 人眼可辨识 spinner（深色背景下系统强调色 spinner 可见，非融入背景）。
  /// artifact: /tmp/autopilot-artifacts/darkmode.placeholder-visible-in-dark.png
  func test_placeholder_visible_in_dark_HUMAN_OBS() throws {
    throw XCTSkip("human-obs: QA 阶段用 CGWindowList 截图（darkmode_loading.png）+ 人眼验证。" +
                  "驱动：defaults write -g AppleInterfaceStyle Dark → open IINA.app → " +
                  "媒体库扫描中（缩略图待生成态）→ CGWindowList 截图。" +
                  "assert: 人眼可辨识 spinner（系统强调色在深色背景下可见）。" +
                  "C5 保证：spinner 走 controlAccentColor（系统动态色，明暗自适应）。" +
                  "artifact: /tmp/autopilot-artifacts/darkmode.placeholder-visible-in-dark.png")
  }

  // MARK: - darkmode.failure-state-visible-in-dark [human-obs]
  // 暗黑模式 + 失败卡 → 文件夹图标失败态深色背景可辨识，与加载中区分

  /// 谓词: darkmode.failure-state-visible-in-dark
  /// QA 阶段：暗黑模式截图，失败卡。
  /// 驱动：暗黑模式 → 触发缩略图失败（不存在的源或超时）→ 截图 darkmode_failed.png。
  /// assert: 人眼可指出失败态（文件夹图标在深色背景可辨识，与加载中 spinner 区分）。
  /// artifact: /tmp/autopilot-artifacts/darkmode.failure-state-visible-in-dark.png
  func test_failure_state_visible_in_dark_HUMAN_OBS() throws {
    throw XCTSkip("human-obs: QA 阶段截图（darkmode_failed.png）。" +
                  "驱动：暗黑模式 → 触发缩略图失败（源不存在/超时）→ CGWindowList 截图。" +
                  "assert: 人眼可指出失败态（文件夹图标），与加载中（spinner）区分。" +
                  "artifact: /tmp/autopilot-artifacts/darkmode.failure-state-visible-in-dark.png")
  }

  // MARK: - darkmode.progress-text-readable-in-dark [human-obs]
  // 暗黑模式 + 扫描中 → 进度文本对比可读

  /// 谓词: darkmode.progress-text-readable-in-dark
  /// QA 阶段：暗黑模式截图，进度 label 区。
  /// 驱动：暗黑模式 → 媒体库扫描中 → 截图 darkmode_scan_progress.png。
  /// assert: 人眼可读「已发现 N 项」数字（secondaryLabelColor 在深色背景对比可读）。
  /// artifact: /tmp/autopilot-artifacts/darkmode.progress-text-readable-in-dark.png
  func test_progress_text_readable_in_dark_HUMAN_OBS() throws {
    throw XCTSkip("human-obs: QA 阶段截图（darkmode_scan_progress.png）。" +
                  "驱动：暗黑模式 → 媒体库扫描中（进度 label 显示「已发现 N 项」）→ CGWindowList 截图。" +
                  "assert: 人眼可读进度文本数字（secondaryLabelColor 深色背景对比可读）。" +
                  "C5 保证：label 走 NSColor.secondaryLabelColor（系统动态色）。" +
                  "artifact: /tmp/autopilot-artifacts/darkmode.progress-text-readable-in-dark.png")
  }
}
