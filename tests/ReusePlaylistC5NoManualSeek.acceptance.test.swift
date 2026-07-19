//
//  ReusePlaylistC5NoManualSeek.acceptance.test.swift
//  iina
//
//  红队验收 — 契约 C5
//  「续播由 mpv resumePlayback 自动 seek；实现代码无手动 seek / 无 videoPosition 写入」
//  黑盒验收（det-machine / grep 断言）
//
//  ⚠️ 信息隔离：本文件仅依据 state.md 契约 C5（不读实现计划），grep onSelectTVShow
//    闭包内不得出现手动 seek / videoPosition 写入。设计依据：mpv resumePlayback
//    （Preference.resumeLastPosition）open 文件后自动读 watch-later seek；
//    手动 seek 会与 openURL 异步加载 race（plan-reviewer B1）。
//
//  CONTRACT_AMBIGUOUS：手动 seek 在 mpv 命令层（seek(_:abs:)）或 videoPosition 写入
//    层均可发生；本测试断言 onSelectTVShow 闭包区域内**均无**这两类调用。
//    无法纯单测（依赖 mpv 命令实际执行），按 prompt 工作规则 3.C 走 grep 断言。
//

import XCTest

final class ReusePlaylistC5NoManualSeekAcceptanceTests: XCTestCase {

  /// 被审计的实现文件（仅 grep，不解析语义）
  static let implFile = "iina/MediaLibrary/MediaLibraryWindowController.swift"

  /// 抽取 onSelectTVShow 闭包体（最近一段 onSelectTVShow = { ... } 区域）
  /// 用于把断言范围限定在闭包内（避免误伤文件其他位置的合法 seek 调用）
  private func extractOnSelectTVShowClosureBody() throws -> String {
    let repoRoot = ProcessInfo.processInfo.environment["REUSEPLAYLIST_REPO_ROOT"]
      ?? FileManager.default.currentDirectoryPath
    let url = URL(fileURLWithPath: repoRoot)
      .appendingPathComponent(ReusePlaylistC5NoManualSeekAcceptanceTests.implFile)
    let src = try String(contentsOf: url, encoding: .utf8)

    // 锚到 "onSelectTVShow = {" 起，到下一个顶层闭包赋值 / 函数定义止
    // 简化：取 onSelectTVShow = { 后 600 字符（足够覆盖整段闭包体）
    guard let range = src.range(of: "onSelectTVShow") else {
      return ""
    }
    let from = src.distance(from: src.startIndex, to: range.lowerBound)
    let end = min(from + 1200, src.count)
    let start = src.index(src.startIndex, offsetBy: from)
    let endIdx = src.index(src.startIndex, offsetBy: end)
    return String(src[start..<endIdx])
  }

  /// C5：onSelectTVShow 闭包内不得出现 `mpv.seek` / `.seek(` 手动 seek 命令
  func test_C5_noManualSeekInOnSelectTVShowClosure() throws {
    let body = try extractOnSelectTVShowClosureBody()
    XCTAssertFalse(
      body.isEmpty,
      "C5：无法定位 onSelectTVShow 闭包（文件可能未定义 onSelectTVShow）"
    )

    // mpv.seek / .seek( — 手动 seek 命令（abs/rel 均算）
    XCTAssertFalse(
      body.contains(".seek(") || body.contains("mpv.seek"),
      "C5：onSelectTVShow 闭包内不得出现手动 seek（.seek( / mpv.seek）— 续播由 mpv resumePlayback 自动 seek。手动 seek 会与 openURL 异步加载 race。"
    )
  }

  /// C5：onSelectTVShow 闭包内不得出现 `videoPosition` 写入
  ///  读 info.videoPosition 在其他地方合法，但在 onSelectTVShow 闭包内写入是 race 源
  func test_C5_noVideoPositionWriteInOnSelectTVShowClosure() throws {
    let body = try extractOnSelectTVShowClosureBody()
    XCTAssertFalse(
      body.isEmpty,
      "C5：无法定位 onSelectTVShow 闭包"
    )

    // 写入形式：`info.videoPosition =` / `videoPosition =`
    XCTAssertFalse(
      body.contains("videoPosition ="),
      "C5：onSelectTVShow 闭包内不得写入 videoPosition — 续播由 mpv resumePlayback 处理，手动写 videoPosition 会与 mpv watch-later 加载 race。"
    )
  }

  /// C5：onSelectTVShow 闭包内不得出现 `info.videoPosition =` 任何赋值
  ///  （含 .second / VideoTime 构造等任何写入路径）
  func test_C5_noVideoTimeConstructionForSeekInClosure() throws {
    let body = try extractOnSelectTVShowClosureBody()
    XCTAssertFalse(
      body.isEmpty,
      "C5：无法定位 onSelectTVShow 闭包"
    )

    // VideoTime(...) 构造 + 赋值的痕迹（resume 不应手工构造 VideoTime）
    XCTAssertFalse(
      body.contains("VideoTime("),
      "C5：onSelectTVShow 闭包内不得构造 VideoTime(...) — 续播不需要手工构造时间，mpv resumePlayback 自动恢复。"
    )
  }

  /// C5（正向）：onSelectTVShow 闭包内必须经 openURLs / openURL 路径
  ///  即续播靠 open 文件 + resumePlayback，不靠 seek
  func test_C5_resumeViaOpenNotViaSeek() throws {
    let body = try extractOnSelectTVShowClosureBody()
    XCTAssertFalse(
      body.isEmpty,
      "C5：无法定位 onSelectTVShow 闭包"
    )

    XCTAssertTrue(
      body.contains("openURLs(") || body.contains("openURL("),
      "C5：续播路径必须经 openURLs/openURL（mpv open + resumePlayback 自动 seek），而非手工 seek"
    )
  }
}
