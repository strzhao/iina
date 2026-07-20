//
//  MediaLibraryStoreProgressFallbackTests.swift
//  iinaTests
//
//  蓝队自写单元测试 — 修复 A4 / C2 契约：
//  MediaLibraryStore.continueWatchingItems / progress(for:) 读 watch-later 失败时
//  fallback 到 entry.mpvProgress?.second（IINA 自持久化的独立进度源）。
//
//  场景（怪奇物语 S03E01）：mpv 写 watch-later 失败（NAS I/O 时序 / pos=NOPTS），
//  读取 Utility.playbackProgressFromWatchLater 返回 nil，旧实现 guard 直接 continue 排除该 entry，
//  导致"继续观看"入口错误消失。修复后 fallback 到 entry.mpvProgress，入口保留。
//

import XCTest
@testable import IINA

final class MediaLibraryStoreProgressFallbackTests: XCTestCase {

  /// 唯一的测试 url，避免与生产 NAS 数据冲突。
  private var testUrl: URL!
  private var testMd5: String!

  override func setUp() {
    super.setUp()
    MediaLibraryStore.disableRescanForTesting = true
    testUrl = URL(fileURLWithPath: "/tmp/iina_cw_fallback_\(UUID().uuidString).mkv")
    testMd5 = Utility.mpvWatchLaterMd5(testUrl, false)
    // 确保无残留 watch-later 文件污染（即使 mpvMd5 已是唯一 hash）。
    let watchLaterFile = Utility.watchLaterURL.appendingPathComponent(testMd5)
    try? FileManager.default.removeItem(at: watchLaterFile)
    // 用 .shared 单例（init 私有），setItemsForTesting 重置 items 避免生产数据干扰。
    MediaLibraryStore.shared.reloadIndexForTesting()
  }

  override func tearDown() {
    // 清理：移除 history 里测试 entry + watch-later 文件 + 重置 store.items。
    HistoryController.shared.$history.withLock { history in
      history.removeAll { $0.url == self.testUrl }
    }
    let watchLaterFile = Utility.watchLaterURL.appendingPathComponent(testMd5)
    try? FileManager.default.removeItem(at: watchLaterFile)
    MediaLibraryStore.shared.setItemsForTesting([])
    MediaLibraryStore.disableRescanForTesting = false
    testUrl = nil
    testMd5 = nil
    super.tearDown()
  }

  /// 谓词 A4.1 / C2：watch-later 缺失、entry.mpvProgress 有值时，continueWatchingItems 仍包含该 item。
  /// 这是 bug 核心场景：mpv 写 watch-later 失败 → 旧实现 guard 排除 → 入口消失。
  /// 修复后 fallback 到 entry.mpvProgress，入口保留。
  func test_continueWatching_falls_back_to_entry_mpvProgress() {
    // 构造 MediaItem（duration 100s，避开 watchedThreshold）。
    let item = MediaItem(
      url: testUrl, cleanedName: "怪奇物语 S03E01", rawName: "r",
      category: .tvShow, tvShowId: "怪奇物语", episodeNumber: 1,
      duration: 100.0, thumbnailPath: nil as URL?)
    MediaLibraryStore.shared.setItemsForTesting([item])

    // 注入 history entry，**不写 watch-later 文件**（模拟 mpv 写失败）。
    // mpvProgress=50s < 95s 阈值，应被保留。
    let entry = PlaybackHistory(
      url: testUrl, duration: 100.0, name: nil, title: "怪奇物语", mpvMd5: testMd5)
    entry.mpvProgress = VideoTime(50.0)
    HistoryController.shared.$history.withLock { history in
      history.insert(entry, at: 0)
    }

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertTrue(cw.contains { $0.url == testUrl },
                  "watch-later 缺失但 entry.mpvProgress 有值时，item 必须仍出现在继续观看（fallback）")
  }

  /// 谓词 A4.2 / C2：progress(for:) 同样 fallback 到 entry.mpvProgress。
  func test_progress_for_falls_back_to_entry_mpvProgress() {
    let item = MediaItem(
      url: testUrl, cleanedName: "fallback prog", rawName: "r",
      category: .movie,
      duration: 200.0, thumbnailPath: nil as URL?)
    MediaLibraryStore.shared.setItemsForTesting([item])

    let entry = PlaybackHistory(
      url: testUrl, duration: 200.0, name: nil, title: nil, mpvMd5: testMd5)
    entry.mpvProgress = VideoTime(77.0)
    HistoryController.shared.$history.withLock { history in
      history.insert(entry, at: 0)
    }

    let progress = MediaLibraryStore.shared.progress(for: item)
    XCTAssertEqual(progress ?? -1, 77.0, accuracy: 0.001,
                   "watch-later 缺失时 progress(for:) 必须 fallback 到 entry.mpvProgress.second")
  }

  /// 谓词 A4.3 / C2：fallback 值仍过 watchedThreshold(0.95)。mpvProgress=98s, duration=100s 应被排除。
  func test_continueWatching_excludes_fallback_above_watched_threshold() {
    let item = MediaItem(
      url: testUrl, cleanedName: "almost done", rawName: "r",
      category: .movie,
      duration: 100.0, thumbnailPath: nil as URL?)
    MediaLibraryStore.shared.setItemsForTesting([item])

    let entry = PlaybackHistory(
      url: testUrl, duration: 100.0, name: nil, title: nil, mpvMd5: testMd5)
    entry.mpvProgress = VideoTime(98.0)  // 98% > 95% 阈值
    HistoryController.shared.$history.withLock { history in
      history.insert(entry, at: 0)
    }

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertFalse(cw.contains { $0.url == testUrl },
                   "fallback mpvProgress ≥ 95% 阈值时必须排除（已看完）")
  }

  /// 谓词 A4.4 / C2：fallback 值为 0（或 nil）时不入选（progress > 0 guard）。
  func test_continueWatching_excludes_zero_fallback_progress() {
    let item = MediaItem(
      url: testUrl, cleanedName: "zero prog", rawName: "r",
      category: .movie,
      duration: 100.0, thumbnailPath: nil as URL?)
    MediaLibraryStore.shared.setItemsForTesting([item])

    let entry = PlaybackHistory(
      url: testUrl, duration: 100.0, name: nil, title: nil, mpvMd5: testMd5)
    // mpvProgress 留 nil（无 fallback 值）。
    HistoryController.shared.$history.withLock { history in
      history.insert(entry, at: 0)
    }

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    XCTAssertFalse(cw.contains { $0.url == testUrl },
                   "watch-later 缺失且 entry.mpvProgress 为 nil 时必须排除")
  }

  /// 谓词 A4.5：watch-later 存在时优先用 watch-later（live 值），fallback 不生效。
  func test_continueWatching_prefers_live_watch_later_over_entry_mpvProgress() throws {
    let item = MediaItem(
      url: testUrl, cleanedName: "live wl", rawName: "r",
      category: .movie,
      duration: 100.0, thumbnailPath: nil as URL?)
    MediaLibraryStore.shared.setItemsForTesting([item])

    // watch-later 文件写入 30s（live 值）。
    let watchLaterFile = Utility.watchLaterURL.appendingPathComponent(testMd5)
    try "start=30\n".write(to: watchLaterFile, atomically: true, encoding: .utf8)

    // entry.mpvProgress 写 60s（应被 watch-later 的 30s 覆盖）。
    let entry = PlaybackHistory(
      url: testUrl, duration: 100.0, name: nil, title: nil, mpvMd5: testMd5)
    entry.mpvProgress = VideoTime(60.0)
    HistoryController.shared.$history.withLock { history in
      history.insert(entry, at: 0)
    }

    let progress = MediaLibraryStore.shared.progress(for: item)
    XCTAssertEqual(progress ?? -1, 30.0, accuracy: 0.001,
                   "watch-later 存在时必须优先用 live 值（30s）而非 entry.mpvProgress（60s）")
  }
}
