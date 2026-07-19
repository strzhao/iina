//
//  ReusePlaylistC1C2OnSelectTVShow.acceptance.test.swift
//  iina
//
//  红队验收 — 契约 C1 / 契约 C2 / 谓词 P4
//  「onSelectTVShow 多集 playlist 契约 + 单文件回退契约」黑盒验收
//
//  ⚠️ 信息隔离：本文件仅依据 state.md 的设计文档 / 契约规约 C1-C2 + 谓词 P4
//    （不读 ## 实现计划区域），不读 iina/ 下任何蓝队实现源码。测试表达
//    "应该实现什么"（设计意图）。
//
//  覆盖：
//    C1：onSelectTVShow(item) 当 item.tvShowId != nil 且 episodes.count >= 1
//        → 必须调用 PlayerCore.activeOrNew.openURLs(_:)（非 openURL）；
//        传入数组首位 == lastWatchedEpisode(tvShowId:) ?? episodes[0] 的 url；
//        传入数组 == [target] + episodes.filter { $0.url != target.url }
//    C2：当 item.tvShowId == nil 或 episodes.isEmpty
//        → 必须调用 openURL(item.url)（不建 playlist）
//    P4：onSelectTVShow 闭包内出现 openURLs( 且首位构造为 target
//
//  CONTRACT_AMBIGUOUS：onSelectTVShow 是 MediaLibraryWindowController 内的闭包，
//    依赖 PlayerCore.activeOrNew 单例与 MediaLibraryStore.shared 单例；纯单测需要
//    注入 fake PlayerCore + fake Store，但 PlayerCore.activeOrNew 不是协议、不可替换，
//    且 openURLs 触发 mpv 命令、依赖 IINA.app 宿主环境。
//    按 prompt 指引（工作规则 3.C），本测试走 det-machine 源码 grep 断言路径，
//    验证闭包源码字面量满足契约。这是 TDD 红灯：实现必须把契约写进源码，
//    否则 grep 失败。
//

import XCTest

final class ReusePlaylistC1C2OnSelectTVShowAcceptanceTests: XCTestCase {

  /// 被审计的实现文件（仅 grep，不解析语义）
  static let implFile = "iina/MediaLibrary/MediaLibraryWindowController.swift"

  /// 读被审计文件的全文（一次），后续多个测试共用
  private func loadSource() throws -> String {
    // 测试运行时 CWD 通常是 IINA.app 的资源目录或测试 bundle 目录；
    // 用 RepoRoot 环境变量回退到仓库根（iina.xcodeproj 所在）。
    let repoRoot = ProcessInfo.processInfo.environment["REUSEPLAYLIST_REPO_ROOT"]
      ?? FileManager.default.currentDirectoryPath
    let url = URL(fileURLWithPath: repoRoot)
      .appendingPathComponent(ReusePlaylistC1C2OnSelectTVShowAcceptanceTests.implFile)
    return try String(contentsOf: url, encoding: .utf8)
  }

  // MARK: - C1 / P4 多集 playlist 契约

  /// P4：onSelectTVShow 闭包内出现 `openURLs(`
  ///  契约 C1：多集情形必须走 openURLs（非 openURL）
  func test_P4_onSelectTVShowClosureCallsOpenURLs() throws {
    let src = try loadSource()

    // 必须存在 onSelectTVShow 闭包定义
    XCTAssertTrue(
      src.contains("onSelectTVShow"),
      "P4/C1：MediaLibraryWindowController 必须定义 onSelectTVShow 闭包"
    )

    // 闭包内必须调用 openURLs（mpv playlist 构建路径）
    // 用 NSRegularExpression 锚到 onSelectTVShow 闭包体内出现 openURLs
    let regex = try NSRegularExpression(
      pattern: #"onSelectTVShow\s*=\s*\{[\s\S]*?openURLs\("#
    )
    let range = NSRange(src.startIndex..., in: src)
    let matches = regex.matches(in: src, range: range)
    XCTAssertGreaterThanOrEqual(
      matches.count, 1,
      "P4/C1：onSelectTVShow 闭包内必须调用 openURLs( — grep 命中 \(matches.count)，期望 >= 1。实现可能误回退到 openURL(item.url) 单文件路径。"
    )
  }

  /// C1：传入数组首位 == lastWatchedEpisode(tvShowId:) ?? episodes[0] 的 url
  ///  即源码内必须出现 `lastWatchedEpisode(tvShowId:` 与 `?? episodes[0]` 的 target 构造
  func test_C1_targetConstructionUsesLastWatchedEpisodeWithFirstEpisodeFallback() throws {
    let src = try loadSource()

    // 必须用 lastWatchedEpisode(tvShowId:) 取续播集
    XCTAssertTrue(
      src.contains("lastWatchedEpisode(tvShowId:"),
      "C1：onSelectTVShow 必须用 store.lastWatchedEpisode(tvShowId:) 取续播集（contract 字面量）"
    )

    // 必须有 fallback 到 episodes[0]（?? episodes[0]）
    //  允许 ?? 两侧空格可变：?? \s* episodes\[0\]
    let fallbackRegex = try NSRegularExpression(
      pattern: #"lastWatchedEpisode\(tvShowId:\s*tvShowId\)\s*\?\?\s*episodes\[0\]"#
    )
    let range = NSRange(src.startIndex..., in: src)
    let matches = fallbackRegex.matches(in: src, range: range)
    XCTAssertGreaterThanOrEqual(
      matches.count, 1,
      "C1：target 必须构造为 `lastWatchedEpisode(tvShowId: tvShowId) ?? episodes[0]` — 命中 \(matches.count)"
    )
  }

  /// C1：传入数组 == [target] + episodes.filter { $0.url != target.url }
  ///  即源码内必须出现 `[target] + episodes.filter` 形态（target 首位、不重复、含全剧）
  func test_C1_orderedEpisodesIsTargetFirstPlusRemainingFiltered() throws {
    let src = try loadSource()

    // [target] + episodes.filter { $0.url != target.url }
    //  允许空白可变；锚到 "[target] + episodes.filter" + "$0.url != target.url"
    let regex = try NSRegularExpression(
      pattern: #"\[\s*target\s*\]\s*\+\s*episodes\.filter\s*\{\s*\$0\.url\s*!=\s*target\.url\s*\}"#
    )
    let range = NSRange(src.startIndex..., in: src)
    let matches = regex.matches(in: src, range: range)
    XCTAssertGreaterThanOrEqual(
      matches.count, 1,
      "C1：playlist 必须构造为 [target] + episodes.filter { $0.url != target.url }（target 首位、不重复、含全剧）— 命中 \(matches.count)"
    )
  }

  /// C1：传入 openURLs 的最终形态必须是 ordered.map { $0.url }（[URL]）
  ///  即 openURLs( 的实参是 .map { $0.url }，证明传 URL 数组而非 MediaItem 数组
  func test_C1_openURLsArgumentIsURLArrayViaMap() throws {
    let src = try loadSource()

    // ordered.map { $0.url } （允许变量名非 ordered，故宽松锚 ".map { $0.url }"）
    let regex = try NSRegularExpression(
      pattern: #"\.map\s*\{\s*\$0\.url\s*\}"#
    )
    let range = NSRange(src.startIndex..., in: src)
    let matches = regex.matches(in: src, range: range)
    XCTAssertGreaterThanOrEqual(
      matches.count, 1,
      "C1：openURLs 实参必须是 [URL]（.map { $0.url }），不能传 MediaItem — 命中 \(matches.count)"
    )
  }

  // MARK: - C2 单文件回退契约

  /// C2：当 item.tvShowId == nil → 必须 openURL(item.url)
  func test_C2_tvShowIdNilFallbackCallsOpenURLWithItemURL() throws {
    let src = try loadSource()

    // guard let tvShowId = item.tvShowId else { ... openURL(item.url) ... }
    //  锚 "guard let tvShowId = item.tvShowId" + 后续 "openURL(item.url)"
    let guardRegex = try NSRegularExpression(
      pattern: #"guard\s+let\s+tvShowId\s*=\s*item\.tvShowId\s+else\s*\{[\s\S]*?openURL\(item\.url\)[\s\S]*?\}"#
    )
    let range = NSRange(src.startIndex..., in: src)
    let matches = guardRegex.matches(in: src, range: range)
    XCTAssertGreaterThanOrEqual(
      matches.count, 1,
      "C2：item.tvShowId == nil 必须回退到 openURL(item.url)（单文件、不建 playlist）— 命中 \(matches.count)"
    )
  }

  /// C2：当 episodes.isEmpty → 必须 openURL(item.url)
  func test_C2_episodesEmptyFallbackCallsOpenURLWithItemURL() throws {
    let src = try loadSource()

    // guard !episodes.isEmpty else { ... openURL(item.url) ... }
    //  或等价的 if episodes.isEmpty { openURL(item.url) }
    let guardRegex = try NSRegularExpression(
      pattern: #"guard\s+!\s*episodes\.isEmpty\s+else\s*\{[\s\S]*?openURL\(item\.url\)[\s\S]*?\}"#
    )
    let range = NSRange(src.startIndex..., in: src)
    let matches = guardRegex.matches(in: src, range: range)
    XCTAssertGreaterThanOrEqual(
      matches.count, 1,
      "C2：tvShowEpisodes.isEmpty 必须回退到 openURL(item.url)（单文件、不建 playlist）— 命中 \(matches.count)"
    )
  }

  /// C2：必须用 store.tvShowEpisodes(tvShowId:) 取剧集（contract 字面量）
  func test_C2_usesTvShowEpisodesQuery() throws {
    let src = try loadSource()

    XCTAssertTrue(
      src.contains("tvShowEpisodes(tvShowId:"),
      "C2：onSelectTVShow 必须用 store.tvShowEpisodes(tvShowId:) 取剧集（contract 字面量）"
    )
  }

  /// C1：PlayerCore.activeOrNew 单例路径（contract 字面量）
  ///  多集与单文件两条路径都经 PlayerCore.activeOrNew，验证至少出现一次
  func test_C1_C2_usesPlayerCoreActiveOrNew() throws {
    let src = try loadSource()

    XCTAssertTrue(
      src.contains("PlayerCore.activeOrNew"),
      "C1/C2：onSelectTVShow 必须经 PlayerCore.activeOrNew（contract 字面量）"
    )
  }
}
