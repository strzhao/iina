//
//  ContinueWatchingItemsFilter.acceptance.test.swift
//  iina
//
//  红队验收测试 — continueWatchingItems() played 过滤移除（黑盒视角，基于 ## 契约规约）
//
//  本测试针对修复：删除 MediaLibraryStore.continueWatchingItems() 中
//    `if entry.played { continue }` 过滤（设计文档 state.md ## 契约规约）。
//
//  修后契约（测试权威源）—— continueWatchingItems() -> [MediaItem]:
//    过滤条件: ① md5 匹配到 MediaItem；
//               ② mpvProgress?.second > 0；
//               ③ 进度 < durationSec × 0.95（watchedThreshold）；
//               ④ 不再依赖 played 字段（played==true 不再导致排除）  ← 本次修复核心
//    排序:  按 addedDate 倒序（最近在前）
//    上限:  ≤ 10 条（continueWatchingLimit）
//    guard: durationSec <= 0 时跳过该条
//
//  覆盖验收场景（P1-P4 各 ≥1 硬断言）：
//    P1 [det-machine]: played==true + mpvProgress=50%×duration → 修后【进入】结果（修前被过滤）  ← 最关键
//    P2 [det-machine]: mpvProgress=95%×duration → 【不进入】（已看完）
//    P3 [det-machine]: mpvProgress=nil → 【不进入】
//    P4 [det-machine]: 返回上限 ≤ 10 条，按 addedDate 倒序
//

import XCTest
@testable import iina

final class ContinueWatchingItemsFilterAcceptanceTests: XCTestCase {

  // MARK: - 常量（取自契约字面量）

  /// 契约 example 用 100s 便于百分比换算。
  private let durationSeconds: Double = 100.0

  // MARK: - 辅助：构造 MediaItem（电影）

  private func makeMediaItem(name: String,
                             urlPath: String = "/tmp/iina_redteam_\(UUID().uuidString).mkv") -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: urlPath),
      cleanedName: name,
      rawName: name + ".1080p",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: durationSeconds,
      thumbnailPath: nil
    )
  }

  // MARK: - 辅助：注入 PlaybackHistory 条目到 HistoryController.shared.history

  /// 构造一条 PlaybackHistory 并 append 到 HistoryController.shared.history。
  /// - Parameter progressSeconds: mpvProgress 秒数；nil 表示无进度（mpvProgress==nil）。
  /// - Parameter played: played 字段值（关键：契约修后不再读此字段，但需注入真实值验证）。
  /// - Parameter addedDate: 记录时间（影响排序）。
  ///
  /// CONTRACT_NOTE: PlaybackHistory 的 designated init(url:duration:name:title:mpvMd5:) 硬编码
  ///   played=true / addedDate=Date() / mpvProgress=nil。played/addedDate/mpvProgress 是 var（非 private），
  ///   故构造后直接赋值以精确控制测试场景。
  ///   duration 是 VideoTime（非 Double），mpvProgress 是 VideoTime?。
  ///   continueWatchingItems 跨类型比较：mpvProgress.second < MediaItem.duration * 0.95。
  ///
  /// CONTRACT_AMBIGUOUS: continueWatchingItems 依赖 HistoryController.shared 单例的 history，
  ///   该数组是 @Atomic，测试通过 append 注入。mpvMd5 经 Utility.mpvWatchLaterMd5(url, ignorePath)
  ///   计算；ignorePath 取 PlayerCore.activeOrNew.ignorePathInWatchLaterConfig（运行时值）。
  ///   测试用 false（默认配置）注入，若 Store 内部 ignorePath 与此不一致，md5 关联会失败——
  ///   此时 P1 断言会失败并暴露 ignorePath seam 缺失，符合红队预期。
  private func injectHistoryEntry(url: URL,
                                  progressSeconds: Double?,
                                  played: Bool,
                                  addedDate: Date) {
    let mpvMd5 = Utility.mpvWatchLaterMd5(url, false)
    let entry = PlaybackHistory(
      url: url,
      duration: durationSeconds,
      name: url.lastPathComponent,
      title: nil,
      mpvMd5: mpvMd5
    )
    // 精确控制测试关键字段（init 硬编码值覆盖）
    entry.played = played
    entry.addedDate = addedDate
    entry.mpvProgress = progressSeconds.map { VideoTime($0) }
    HistoryController.shared.history.append(entry)
  }

  /// 清理：移除本测试注入的 history 条目（按 url 前缀 /tmp/iina_redteam_ 识别）。
  private func cleanupInjectedHistory() {
    HistoryController.shared.history.removeAll { $0.url.path.hasPrefix("/tmp/iina_redteam_") }
  }

  override func tearDown() {
    cleanupInjectedHistory()
    super.tearDown()
  }

  // MARK: - P1 [det-machine] 核心：played==true + 进度<95% → 进入结果（修前被过滤）

  /// 谓词: P1「played==true + mpvProgress=50%×duration → 修后进入 continueWatchingItems 结果」
  ///
  /// 这是本次修复的核心断言。修前 `if entry.played { continue }` 把 played==true（即全部历史条目，
  /// 因 HistoryController.add 硬编码 played=true）全过滤掉 → 列表永远空。修后删除该过滤，
  /// played==true 但进度有效且 < 95% 的条目必须进入结果。
  ///
  /// Mutation-Survival: 若实现回退成「保留 played 过滤」，此测试必挂（played==true 被排除）。
  ///                   若实现回退成「过滤所有」，test_continueWatching_nil_progress_excludes 也会挂。
  func test_P1_playedTrue_withProgress_entersResult() {
    let item = makeMediaItem(name: "P1播放过半")
    // played=true（模拟真实历史条目），进度 50% × 100s = 50s（明确 < 95%）
    injectHistoryEntry(url: item.url, progressSeconds: 50.0, played: true, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    // 硬断言：played==true 不应再导致排除
    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "P1 失败：played==true 且进度 50%(< 95%×duration) 必须进入继续观看。"
                  + "实际 cw: \(cw.map { $0.cleanedName })。"
                  + "若此断言失败，说明 played 过滤仍存在（修复未生效）。")
  }

  /// 谓词: P1 强化 — played==true + 进度 94%（边界 < 95%）也进入
  /// 防止实现用「played==true 且进度<X」的更严格判据绕过。
  func test_P1_playedTrue_94_percent_boundary_entersResult() {
    let item = makeMediaItem(name: "P1边界94")
    injectHistoryEntry(url: item.url, progressSeconds: 94.0, played: true, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "P1 边界失败：played==true 且进度 94%(< 95%×duration) 必须进入继续观看。"
                  + "实际 cw: \(cw.map { $0.cleanedName })")
  }

  // MARK: - P2 [det-machine] 95% 进度 → 不进入（已看完）

  /// 谓词: P2「mpvProgress=95%×duration → 不进入（已看完）」
  ///
  /// 修后「已看完」唯一判据是进度 ≥ duration × watchedThreshold(0.95)。
  /// 此测试防止实现把过滤整个删掉（含 95% 判断）变成「全部进入」。
  ///
  /// Mutation-Survival: 若实现回退成「不过滤任何东西」（删过头），此测试必挂（95% 也进）。
  func test_P2_95_percent_progress_excludes() {
    let item = makeMediaItem(name: "P2已看完")
    // 95% × 100s = 95s，正好等于 watchedThreshold 边界 → 不进
    injectHistoryEntry(url: item.url, progressSeconds: 95.0, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "P2 失败：进度 95%(≥ 95%×duration = 已看完) 不得进入继续观看。"
                   + "实际 cw 含该 item: \(cw.contains { $0.url == item.url })。"
                   + "若此断言失败，说明 watchedThreshold(0.95) 判断被误删。")
  }

  /// 谓词: P2 扩展 — >95%（96/99/100%）一律不进
  func test_P2_above_95_percent_all_excluded() {
    for pct in [96.0, 99.0, 100.0] {
      let item = makeMediaItem(name: "P2超\(Int(pct))")
      injectHistoryEntry(url: item.url, progressSeconds: pct, played: false, addedDate: Date())
      MediaLibraryStore.shared.setItemsForTesting([item])

      let cw = MediaLibraryStore.shared.continueWatchingItems()

      XCTAssertFalse(cw.contains { $0.url == item.url },
                     "P2 扩展失败：\(Int(pct))% 进度(> 95%) 不得进入继续观看。"
                     + "实际 cw: \(cw.map { $0.cleanedName })")
      cleanupInjectedHistory()
    }
  }

  // MARK: - P3 [det-machine] mpvProgress=nil → 不进入

  /// 谓词: P3「mpvProgress=nil → 不进入」
  ///
  /// 前置条件 mpvProgress?.second > 0 必须保留。
  /// Mutation-Survival: 若实现把进度 guard 删掉，此测试必挂（nil/0 进度也进）。
  func test_P3_nil_progress_excludes() {
    let item = makeMediaItem(name: "P3无进度")
    injectHistoryEntry(url: item.url, progressSeconds: nil, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "P3 失败：mpvProgress==nil 的视频不得进入继续观看。"
                   + "实际 cw 含该 item: \(cw.contains { $0.url == item.url })")
  }

  /// 谓词: P3 扩展 — 进度 0 秒也不进（mpvProgress?.second > 0 guard）
  func test_P3_zero_progress_excludes() {
    let item = makeMediaItem(name: "P3零进度")
    injectHistoryEntry(url: item.url, progressSeconds: 0.0, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "P3 零进度失败：mpvProgress.second == 0 不得进入继续观看。"
                   + "实际 cw: \(cw.map { $0.cleanedName })")
  }

  // MARK: - P4 [det-machine] 上限 ≤ 10 + addedDate 倒序

  /// 谓词: P4-a「返回上限 ≤ 10 条」
  ///
  /// 注入 15 个有效进度项，断言结果 ≤ continueWatchingLimit(10)。
  /// Mutation-Survival: 若实现把 prefix(limit) 删掉，此测试必挂（返回 15）。
  func test_P4a_capped_at_10() {
    var items: [MediaItem] = []
    for i in 0..<15 {
      let item = makeMediaItem(name: "P4电影\(i)")
      injectHistoryEntry(url: item.url,
                         progressSeconds: 50.0,
                         played: false,
                         addedDate: Date().addingTimeInterval(TimeInterval(i)))
      items.append(item)
    }
    MediaLibraryStore.shared.setItemsForTesting(items)

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertLessThanOrEqual(cw.count, 10,
                             "P4a 失败：继续观看上限 ≤ 10 条（continueWatchingLimit），实际: \(cw.count)")
    XCTAssertGreaterThanOrEqual(cw.count, 1,
                                "P4a 失败：15 个有效进度项应至少返回 1 条，实际: \(cw.count)")
  }

  /// 谓词: P4-b「按 addedDate 倒序（最近在前）」
  ///
  /// 注入 3 个不同 addedDate 的项，断言 cw[0] 最新、cw[2] 最旧。
  /// Mutation-Survival: 若实现回退成「不排序」或「正序」，断言必挂。
  func test_P4b_sorted_by_addedDate_desc() {
    let base = Date()
    let itemOld = makeMediaItem(name: "P4旧")
    let itemMid = makeMediaItem(name: "P4中")
    let itemNew = makeMediaItem(name: "P4新")

    injectHistoryEntry(url: itemOld.url, progressSeconds: 50.0, played: false,
                       addedDate: base.addingTimeInterval(-100))
    injectHistoryEntry(url: itemMid.url, progressSeconds: 50.0, played: false,
                       addedDate: base.addingTimeInterval(-50))
    injectHistoryEntry(url: itemNew.url, progressSeconds: 50.0, played: false,
                       addedDate: base)

    MediaLibraryStore.shared.setItemsForTesting([itemOld, itemMid, itemNew])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertEqual(cw.count, 3, "P4b 前置失败：应有 3 条继续观看，实际: \(cw.count)")
    XCTAssertEqual(cw[0].url, itemNew.url,
                   "P4b 失败：第 1 条应为 addedDate 最新（base）的 item，实际 cw[0]: \(cw.first?.cleanedName ?? "nil")")
    XCTAssertEqual(cw[1].url, itemMid.url,
                   "P4b 失败：第 2 条应为 addedDate 次新（base-50），实际 cw[1]: \(cw.count >= 2 ? cw[1].cleanedName : "nil")")
    XCTAssertEqual(cw[2].url, itemOld.url,
                   "P4b 失败：第 3 条应为 addedDate 最旧（base-100），实际 cw[2]: \(cw.count >= 3 ? cw[2].cleanedName : "nil")")
  }

  // MARK: - 契约 guard：durationSec <= 0 跳过

  /// 谓词: 契约「duration guard: durationSec <= 0 时跳过该条」
  ///
  /// 修后 duration guard 须保留（设计文档 ## 不变量）。
  /// Mutation-Survival: 若实现误删 duration guard，且 MediaItem.duration<=0，零/负时长项可能误入。
  func test_durationGuard_zeroOrNegative_skips() {
    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_redteam_zerodur_\(UUID().uuidString).mkv"),
      cleanedName: "零时长",
      rawName: "零时长.1080p",
      category: .movie,
      duration: 0.0,  // durationSec <= 0
      thumbnailPath: nil
    )
    injectHistoryEntry(url: item.url, progressSeconds: 1.0, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "duration guard 失败：MediaItem.duration <= 0 的视频不得进入继续观看（避免 0 除/误判）。"
                   + "实际 cw: \(cw.map { $0.cleanedName })")
  }

  // MARK: - 跨契约组合：played==true + 多条混合（真实场景模拟）

  /// 谓词: 真实场景模拟 — 全部 played==true（与生产 history.plist 一致），
  /// 不同进度混合，验证修后 played 不再影响过滤，仅进度 < 95% 决定入选。
  ///
  /// 这是 P1 的真实化加强：生产环境 18 条历史 played 全 true，修后应按进度正确筛选。
  func test_realWorld_allPlayedTrue_mixedProgress_filtersByProgressOnly() {
    let inItem1 = makeMediaItem(name: "真实进度50")   // 50% → 进
    let inItem2 = makeMediaItem(name: "真实进度80")   // 80% → 进
    let outItem1 = makeMediaItem(name: "真实已看完96") // 96% → 不进
    let outItem2 = makeMediaItem(name: "真实无进度")   // nil → 不进

    // 全部 played==true（模拟生产）
    injectHistoryEntry(url: inItem1.url, progressSeconds: 50.0, played: true, addedDate: Date().addingTimeInterval(-30))
    injectHistoryEntry(url: inItem2.url, progressSeconds: 80.0, played: true, addedDate: Date().addingTimeInterval(-20))
    injectHistoryEntry(url: outItem1.url, progressSeconds: 96.0, played: true, addedDate: Date().addingTimeInterval(-10))
    injectHistoryEntry(url: outItem2.url, progressSeconds: nil, played: true, addedDate: Date())

    MediaLibraryStore.shared.setItemsForTesting([inItem1, inItem2, outItem1, outItem2])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    // 应进入的 2 条
    XCTAssertTrue(cw.contains { $0.url == inItem1.url },
                  "真实场景失败：played==true + 50% 进度必须进入，实际 cw: \(cw.map { $0.cleanedName })")
    XCTAssertTrue(cw.contains { $0.url == inItem2.url },
                  "真实场景失败：played==true + 80% 进度必须进入，实际 cw: \(cw.map { $0.cleanedName })")
    // 不应进入的 2 条
    XCTAssertFalse(cw.contains { $0.url == outItem1.url },
                   "真实场景失败：96% 进度不得进入（played==true 不是判据，进度才是）")
    XCTAssertFalse(cw.contains { $0.url == outItem2.url },
                   "真实场景失败：无进度不得进入")
    // 数量精确
    XCTAssertEqual(cw.count, 2,
                   "真实场景失败：4 条历史（2 进 2 不进）应返回正好 2 条，实际: \(cw.count)")
  }

  // MARK: - Mutation-Survival 自检：空 Store

  /// No-op 自检：空 Store（无 history 关联）→ continueWatchingItems 返回空。
  /// 防止实现返回全量 items 而非过滤结果。
  func test_mutationSurvival_emptyStore_returnsEmpty() {
    MediaLibraryStore.shared.setItemsForTesting([])
    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.isEmpty,
                 "Mutation 自检失败：空 Store 的 continueWatchingItems 必须为空数组，实际: \(cw.count)")
  }
}
