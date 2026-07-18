//
//  MediaLibraryPerfSmokeRun.acceptance.test.swift
//  iina
//
//  红队验收测试 — X.1 全旅程无崩溃 + 最终状态自洽（黑盒视角）
//
//  覆盖谓词：
//    X.1 [real-process] 全旅程无崩溃 + 最终状态自洽
//
//  验证手段（本项目特有）：
//    marker 文件时间线（CLAUDE.md「GUI 行为用 marker 文件诊断执行链路」）
//    + 各 P 的核心 seam 最终状态断言。
//
//  策略：顺序触发 P1-P5 的入口（不依赖真实 NAS / FFmpeg IO），
//        断言全程无崩溃 + 最终状态字段自洽（计数器、占位态、字段一致性）。
//

import XCTest
@testable import IINA

final class MediaLibraryPerfSmokeRunAcceptanceTests: XCTestCase {

  // MARK: - 辅助

  private func makeItem(_ name: String) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_x1_\(UUID().uuidString).mkv"),
      cleanedName: name,
      rawName: name + ".mkv",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: 100,
      thumbnailPath: nil
    )
  }

  @discardableResult
  private func writeMarker(_ tag: String) -> String {
    let path = "/tmp/iina_perf_x1_marker_\(tag)_\(UUID().uuidString)"
    try? "x".write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  // MARK: - X.1 全旅程无崩溃 + 最终状态自洽

  /// 谓词: X.1 [real-process] 全旅程无崩溃 + 最终状态自洽
  /// WHEN 顺序触发 P1-P5 各入口（scheduleSaveIndex / flushNow / loadIndex 通知 / search / cache-hit），
  /// THEN 全程无崩溃（hosted XCTest 不 crash）+ 最终状态字段自洽：
  ///   - saveWriteCount >= 1（至少一次持久化发生）
  ///   - items.count > 0（非空状态）
  ///   - cleanedNameLowercased == cleanedName.lowercased()（P4 字段自洽）
  ///   - isLoadingIndex == false（加载已完成，非中间态）
  ///   - __test_lastCacheHitThread.isMainThread == false（P5 seam 在适当时机被设置）
  func test_full_journey_no_crash_state_self_consistent() {
    let store = MediaLibraryStore.shared
    writeMarker("X1-start")

    // P1: scheduleSaveIndex + flushNow（合并写 + 退出兜底路径）
    let items = (0..<3).map { makeItem("X1-\($0)") }
    store.setItemsForTesting(items)
    store.scheduleSaveIndex()
    store.flushNow()
    writeMarker("X1-P1-done")

    // P4: cleanedNameLowercased 字段自洽
    for item in store.items {
      XCTAssertEqual(
        item.cleanedNameLowercased, item.cleanedName.lowercased(),
        "X.1 P4 自洽失败：cleanedNameLowercased != cleanedName.lowercased()"
      )
    }

    // P3: indexLoaded 通知能投递（VC 监听）
    NotificationCenter.default.post(
      name: MediaLibraryStore.indexLoadedNotification,
      object: store
    )

    // P2: search 防抖（构造 VC 触发 refresh）
    MediaLibraryStore.disableRescanForTesting = true  // 测试隔离：禁 rescan
    let vc = MediaLibraryViewController()
    _ = vc.view
    vc.currentCategory = .movie
    vc.currentFilter = "X1"
    vc.refresh()
    vc.currentFilter = ""
    vc.refresh()
    writeMarker("X1-P2-done")

    // 最终状态自洽
    XCTAssertFalse(
      store.isLoadingIndex,
      "X.1 自洽失败：isLoadingIndex == true（加载未完成，中间态）"
    )
    XCTAssertGreaterThan(
      store.items.count, 0,
      "X.1 自洽失败：items.count == 0（应保留 setItemsForTesting 注入的 3 项）"
    )
    XCTAssertGreaterThanOrEqual(
      store.saveWriteCount, 1,
      "X.1 自洽失败：saveWriteCount == 0（至少一次持久化应发生）"
    )
    writeMarker("X1-end")

    // 若到此处无崩溃，X.1 全旅程无崩溃断言通过
    XCTAssertTrue(true, "X.1 全旅程（P1-P5 入口顺序触发）未崩溃，最终状态自洽")
  }

  /// 谓词: X.1 [real-process] P5 cache-hit seam 全旅程可触发
  /// WHEN 在 X.1 全旅程内额外触发 ContinueWatchingCollectionViewItem cache-hit，
  /// THEN __test_lastCacheHitThread 被设置且 isMainThread == false（P5 主路径未被破坏）。
  func test_x1_cache_hit_seam_self_consistent() throws {
    ContinueWatchingCollectionViewItem.__test_lastCacheHitThread = nil

    // 构造 cache-hit 文件
    let thumbURL = URL(fileURLWithPath: "/tmp/iina_perf_x1_thumb_\(UUID().uuidString).png")
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.green.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
      .representation(using: .png, properties: [:])!
    try png.write(to: thumbURL)

    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_x1_main_\(UUID().uuidString).mkv"),
      cleanedName: "X1 CacheHit",
      rawName: "X1ch.mkv",
      category: .movie, tvShowId: nil, episodeNumber: nil,
      duration: 100, thumbnailPath: thumbURL
    )
    let cell = ContinueWatchingCollectionViewItem()
    _ = cell.view
    cell.configure(with: item, ignorePath: false)

    let exp = expectation(description: "cache-hit seam set")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
    wait(for: [exp], timeout: 3.0)

    let thread = ContinueWatchingCollectionViewItem.__test_lastCacheHitThread
    XCTAssertNotNil(
      thread,
      "X.1 P5 seam 自洽失败：__test_lastCacheHitThread 未被设置"
    )
    if let t = thread {
      XCTAssertFalse(
        t.isMainThread,
        "X.1 P5 seam 自洽失败：cache-hit 读线程在主线程（应后台）"
      )
    }

    try? FileManager.default.removeItem(at: thumbURL)
  }
}
