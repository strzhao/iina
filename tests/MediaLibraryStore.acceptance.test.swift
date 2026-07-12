//
//  MediaLibraryStore.acceptance.test.swift
//  iina
//
//  红队验收测试 — Store 持久化与查询（黑盒视角，基于 ## 契约规约）
//
//  覆盖验收场景：
//    场景 7-P1 [det-machine]: 存在有进度未完成视频 → 顶部继续观看区 children.count >= 1
//    场景 14-P1 [det-machine]: 进度 >= 95% → 不在继续观看区显示
//  覆盖契约边界值（continueWatchingItems）：
//    正例: mpvProgress = 50% × duration → 进
//    边界: mpvProgress = 94% × duration → 进
//    反例: mpvProgress = 95% × duration → 不进（已看完）
//    上限: ≤ 10 条
//    排序: 按 lastPlayed 排序
//  覆盖契约查询：
//    items(category:filter:), continueWatchingItems(), tvShowEpisodes(tvShowId:), lastWatchedEpisode(tvShowId:)
//  跨系统数据流：MediaItem.url → mpvWatchLaterMd5 → HistoryController 字段一致性
//

import XCTest
@testable import iina

final class MediaLibraryStoreAcceptanceTests: XCTestCase {

  // MARK: - 辅助：构造带进度的 PlaybackHistory 并注入 HistoryController

  /// 视频时长（秒），契约 example 用 100s 便于百分比计算
  private let durationSeconds: Double = 100.0

  /// 构造一个 MediaItem（电影），url 指向虚拟路径
  private func makeMediaItem(name: String, urlPath: String = "/tmp/iina_test_\(UUID().uuidString).mkv") -> MediaItem {
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

  /// 构造 PlaybackHistory 条目并注入 HistoryController.shared.history
  /// - progressSeconds: mpvProgress 秒数；nil 表示无进度
  /// - played: 是否已标记 played
  /// - addedDate: 记录时间（影响排序）
  private func injectHistoryEntry(url: URL, progressSeconds: Double?, played: Bool, addedDate: Date) {
    // 注意：HistoryController.add 签名 add(_ url:, duration:, title:, _ ignorePath:)
    // 但 add 内部会重算 mpvMd5 且可能去重；为精确控制 mpvProgress，这里直接构造 PlaybackHistory。
    // CONTRACT_NOTE: PlaybackHistory.duration 是 VideoTime 类型（非 Double），mpvProgress 是 VideoTime?
    // MediaLibraryStore.continueWatchingItems 须按 MediaItem.duration(Double?) 与 history.mpvProgress(VideoTime)
    // 做跨类型比较：< duration * 0.95。红队此处注入真实 PlaybackHistory 验证字段一致性。
    let durationVT = VideoTime(durationSeconds)
    let progressVT = progressSeconds.map { VideoTime($0) }
    let mpvMd5 = Utility.mpvWatchLaterMd5(url, false)  // ignorePath=false，与默认一致
    let entry = PlaybackHistory(
      url: url,
      name: url.lastPathComponent,
      mpvMd5: mpvMd5,
      played: played,
      addedDate: addedDate,
      duration: durationVT,
      mpvProgress: progressVT,
      title: nil
    )
    // CONTRACT_AMBIGUOUS: HistoryController.history 是 @Atomic [PlaybackHistory]，测试直接 append 注入。
    // 若蓝队 Store 通过 HistoryController.shared.history 读取，此注入路径与生产一致。
    HistoryController.shared.history.append(entry)
  }

  /// 清理：移除本测试注入的 history 条目（按 url 前缀 /tmp/iina_test_ 识别）
  private func cleanupInjectedHistory() {
    HistoryController.shared.history.removeAll { $0.url.path.hasPrefix("/tmp/iina_test_") }
  }

  override func tearDown() {
    cleanupInjectedHistory()
    super.tearDown()
  }

  // MARK: - 场景 7-P1 + 契约正例：50% 进度进继续观看

  /// 谓词: 契约正例「mpvProgress = 50% × duration → 进继续观看」
  /// 谓词: 场景7-P1「存在有进度未完成视频 → 继续观看区 children.count >= 1」
  func test_continueWatching_includes_50_percent_progress() {
    let item = makeMediaItem(name: "电影50")
    injectHistoryEntry(url: item.url, progressSeconds: 50.0, played: false, addedDate: Date())

    // 注入 MediaItem 到 Store（通过扫描或直接设）
    // CONTRACT_NOTE: MediaLibraryStore 是单例，持有 [MediaItem]。测试通过临时设置 items 验证查询。
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "50% 进度（< 95% × duration）必须进入继续观看，实际 cw: \(cw.map { $0.cleanedName })")
  }

  // MARK: - 契约边界：94% 进度进继续观看

  /// 谓词: 契约边界「mpvProgress = 94% × duration → 进继续观看」
  func test_continueWatching_includes_94_percent_boundary() {
    let item = makeMediaItem(name: "电影94")
    // 94% × 100s = 94s
    injectHistoryEntry(url: item.url, progressSeconds: 94.0, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "94% 进度（边界，< 95%）必须进入继续观看，实际 cw: \(cw.map { $0.cleanedName })")
  }

  // MARK: - 场景 14-P1 + 契约反例：95% 进度不进继续观看

  /// 谓词: 契约反例「mpvProgress = 95% × duration → 不进继续观看（已看完）」
  /// 谓词: 场景14-P1 [det-machine]: ∀ item: item.text 不含已看完视频片名
  func test_continueWatching_excludes_95_percent_boundary() {
    let item = makeMediaItem(name: "电影95")
    // 95% × 100s = 95s
    injectHistoryEntry(url: item.url, progressSeconds: 95.0, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "95% 进度（≥ 95% × duration）不得进入继续观看，实际 cw 含该 item: \(cw.contains { $0.url == item.url })")
  }

  // MARK: - 契约边界：96%/99%/100% 同样不进

  /// 谓词: 契约反例扩展（>95% 一律不进）
  func test_continueWatching_excludes_above_95_percent() {
    for pct in [96.0, 99.0, 100.0] {
      let item = makeMediaItem(name: "电影\(Int(pct))")
      injectHistoryEntry(url: item.url, progressSeconds: pct, played: false, addedDate: Date())
      MediaLibraryStore.shared.setItemsForTesting([item])

      let cw = MediaLibraryStore.shared.continueWatchingItems()
      XCTAssertFalse(cw.contains { $0.url == item.url },
                     "\(Int(pct))% 进度不得进入继续观看")
      cleanupInjectedHistory()
    }
  }

  // MARK: - 契约：played==true 不进继续观看

  /// 谓词: 契约「mpvProgress != nil 且 < duration*0.95 且 played==false」
  /// played==true 即使有进度也不进
  func test_continueWatching_excludes_played_true() {
    let item = makeMediaItem(name: "已看电影")
    injectHistoryEntry(url: item.url, progressSeconds: 50.0, played: true, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "played==true 的视频不得进入继续观看")
  }

  // MARK: - 契约：无进度（mpvProgress==nil）不进

  /// 谓词: 契约「mpvProgress != nil」前置条件
  func test_continueWatching_excludes_nil_progress() {
    let item = makeMediaItem(name: "无进度电影")
    injectHistoryEntry(url: item.url, progressSeconds: nil, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "mpvProgress==nil 的视频不得进入继续观看")
  }

  // MARK: - 契约：≤10 上限

  /// 谓词: 契约「继续观看上限: ≤ 10 条」
  func test_continueWatching_capped_at_10() {
    var items: [MediaItem] = []
    for i in 0..<15 {
      let item = makeMediaItem(name: "电影\(i)")
      injectHistoryEntry(url: item.url, progressSeconds: 50.0, played: false,
                         addedDate: Date().addingTimeInterval(TimeInterval(i)))
      items.append(item)
    }
    MediaLibraryStore.shared.setItemsForTesting(items)

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertLessThanOrEqual(cw.count, 10,
                             "继续观看上限 ≤ 10 条，实际: \(cw.count)")
    XCTAssertGreaterThanOrEqual(cw.count, 1, "15 个有效进度项应至少返回 1 条")
  }

  // MARK: - 契约：按 lastPlayed 排序

  /// 谓词: 契约「按 lastPlayed 排序」
  /// 实现：注入 3 个不同 addedDate 的项，断言 cw 按 addedDate 倒序（最新在前）
  func test_continueWatching_sorted_by_lastPlayed_desc() {
    let base = Date()
    let itemOld = makeMediaItem(name: "旧")
    let itemMid = makeMediaItem(name: "中")
    let itemNew = makeMediaItem(name: "新")

    injectHistoryEntry(url: itemOld.url, progressSeconds: 50, played: false, addedDate: base.addingTimeInterval(-100))
    injectHistoryEntry(url: itemMid.url, progressSeconds: 50, played: false, addedDate: base.addingTimeInterval(-50))
    injectHistoryEntry(url: itemNew.url, progressSeconds: 50, played: false, addedDate: base)

    MediaLibraryStore.shared.setItemsForTesting([itemOld, itemMid, itemNew])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertEqual(cw.count, 3, "应有 3 条继续观看")
    // 倒序：新 → 中 → 旧
    XCTAssertEqual(cw[0].url, itemNew.url, "第 1 条应为最新 played 的 item")
    XCTAssertEqual(cw[1].url, itemMid.url, "第 2 条应为次新")
    XCTAssertEqual(cw[2].url, itemOld.url, "第 3 条应为最旧")
  }

  // MARK: - 契约：items(category:filter:) 分类过滤

  /// 谓词: 契约 items(category:filter:)
  func test_items_filter_by_category_and_text() {
    let movie1 = makeMediaItem(name: "小丑")
    let movie2 = makeMediaItem(name: "盗梦空间")
    let tvItem = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_test_tv1.mkv"),
      cleanedName: "怪奇物语", rawName: "怪奇物语.1080p", category: .tvShow,
      tvShowId: "怪奇物语", episodeNumber: 1, duration: 100, thumbnailPath: nil
    )
    MediaLibraryStore.shared.setItemsForTesting([movie1, movie2, tvItem])

    // category 过滤
    let movies = MediaLibraryStore.shared.items(category: .movie, filter: nil)
    XCTAssertEqual(movies.count, 2, "movie 分类应 2 项")
    let tvShows = MediaLibraryStore.shared.items(category: .tvShow, filter: nil)
    XCTAssertEqual(tvShows.count, 1, "tvShow 分类应 1 项")

    // 文本过滤
    let filtered = MediaLibraryStore.shared.items(category: .movie, filter: "小丑")
    XCTAssertEqual(filtered.count, 1, "filter=「小丑」应仅 1 项")
    XCTAssertEqual(filtered.first?.cleanedName, "小丑", "过滤结果应为「小丑」")
  }

  // MARK: - 契约：tvShowEpisodes(tvShowId:) 按 episodeNumber 排序

  /// 谓词: 契约 tvShowEpisodes(tvShowId:)「按 episodeNumber 排序」
  func test_tvShowEpisodes_sorted_by_episodeNumber() {
    let showId = "怪奇物语"
    let ep3 = MediaItem(url: URL(fileURLWithPath: "/tmp/ep3.mkv"), cleanedName: "E03",
                        rawName: "r3", category: .tvShow, tvShowId: showId, episodeNumber: 3, duration: 100, thumbnailPath: nil)
    let ep1 = MediaItem(url: URL(fileURLWithPath: "/tmp/ep1.mkv"), cleanedName: "E01",
                        rawName: "r1", category: .tvShow, tvShowId: showId, episodeNumber: 1, duration: 100, thumbnailPath: nil)
    let ep2 = MediaItem(url: URL(fileURLWithPath: "/tmp/ep2.mkv"), cleanedName: "E02",
                        rawName: "r2", category: .tvShow, tvShowId: showId, episodeNumber: 2, duration: 100, thumbnailPath: nil)
    MediaLibraryStore.shared.setItemsForTesting([ep3, ep1, ep2])

    let eps = MediaLibraryStore.shared.tvShowEpisodes(tvShowId: showId)
    XCTAssertEqual(eps.count, 3, "应返回 3 集")
    XCTAssertEqual(eps[0].episodeNumber, 1, "第 1 集 episodeNumber==1")
    XCTAssertEqual(eps[1].episodeNumber, 2, "第 2 集 episodeNumber==2")
    XCTAssertEqual(eps[2].episodeNumber, 3, "第 3 集 episodeNumber==3")
  }

  // MARK: - 契约：lastWatchedEpisode(tvShowId:)

  /// 谓词: 契约 lastWatchedEpisode(tvShowId:) -> MediaItem?
  /// 谓词: 场景9-P1 [det-machine]: 高亮上次观看的集（lastWatchedEpisode 非 nil）
  func test_lastWatchedEpisode_returns_most_recent() {
    let showId = "怪奇物语"
    let ep1 = MediaItem(url: URL(fileURLWithPath: "/tmp/lw_ep1.mkv"), cleanedName: "E01",
                        rawName: "r1", category: .tvShow, tvShowId: showId, episodeNumber: 1, duration: 100, thumbnailPath: nil)
    let ep3 = MediaItem(url: URL(fileURLWithPath: "/tmp/lw_ep3.mkv"), cleanedName: "E03",
                        rawName: "r3", category: .tvShow, tvShowId: showId, episodeNumber: 3, duration: 100, thumbnailPath: nil)
    MediaLibraryStore.shared.setItemsForTesting([ep1, ep3])

    // 注入 ep3 有进度（最近观看）
    injectHistoryEntry(url: ep3.url, progressSeconds: 30, played: false, addedDate: Date())

    let last = MediaLibraryStore.shared.lastWatchedEpisode(tvShowId: showId)
    XCTAssertNotNil(last, "有进度的剧应返回 lastWatchedEpisode 非 nil")
    XCTAssertEqual(last?.url, ep3.url, "lastWatchedEpisode 应为 E03")
  }

  /// 谓词: 契约 lastWatchedEpisode 无进度时返回 nil
  func test_lastWatchedEpisode_returns_nil_when_no_progress() {
    let showId = "无进度剧"
    let ep1 = MediaItem(url: URL(fileURLWithPath: "/tmp/nl_ep1.mkv"), cleanedName: "E01",
                        rawName: "r1", category: .tvShow, tvShowId: showId, episodeNumber: 1, duration: 100, thumbnailPath: nil)
    MediaLibraryStore.shared.setItemsForTesting([ep1])
    // 不注入任何进度

    let last = MediaLibraryStore.shared.lastWatchedEpisode(tvShowId: showId)
    XCTAssertNil(last, "无进度的剧 lastWatchedEpisode 应为 nil")
  }

  // MARK: - 跨系统数据流：mpvMd5 字段一致性

  /// 谓词: 设计文档「进度关联通过 Utility.mpvWatchLaterMd5(url, ignorePath) 计 mpvMd5 查 HistoryController.history」
  /// 验证：MediaItem.url → mpvWatchLaterMd5 与 HistoryController 注入的 mpvMd5 一致
  func test_progress_association_mpvMd5_consistency() {
    let item = makeMediaItem(name: "一致性测试")
    // Store 内部应使用 Utility.mpvWatchLaterMd5(item.url, ignorePath) 计算
    // ignorePath 须与 PlayerCore.activeOrNew.ignorePathInWatchLaterConfig 一致
    // 测试用 false（默认值）注入 history，验证 Store 查询能命中
    injectHistoryEntry(url: item.url, progressSeconds: 50, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "mpvMd5 一致性失败：Store 未能通过 mpvWatchLaterMd5 关联到 history 条目。"
                  + "可能 ignorePath 取值与 HistoryController.add 不一致（应为 PlayerCore.activeOrNew.ignorePathInWatchLaterConfig）")
  }

  // MARK: - Mutation-Survival 自检

  /// No-op 自检：空 Store → continueWatchingItems 返回空
  func test_continueWatching_empty_store_returns_empty() {
    MediaLibraryStore.shared.setItemsForTesting([])
    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.isEmpty, "空 Store 的 continueWatchingItems 必须为空数组")
  }

  /// Boundary 自检：刚好 95.0% 不进，94.999% 进（浮点边界）
  /// CONTRACT_AMBIGUOUS: 设计文档说「< duration * 0.95」，94.999% 是否进取决于浮点比较。
  /// 此处验证 94.9% 进（明确 < 95%）。
  func test_continueWatching_boundary_94_9_percent_includes() {
    let item = makeMediaItem(name: "电影94.9")
    injectHistoryEntry(url: item.url, progressSeconds: 94.9, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "94.9% 进度（明确 < 95%）必须进入继续观看")
  }
}
