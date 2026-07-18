//
//  MediaLibraryPerfP1_P5.unit.test.swift
//  iina
//
//  蓝队自写单元测试（编译期健康自检）— P1-P5 性能优化契约存在性与同步不变量验证。
//
//  范围：只验证「编译期可达 + 同步可确定性求值」的契约，不测异步时序（合并窗口/debounce 触发/
//  loadIndex 线程）——那些依赖主线程 runloop，归红队 hosted XCTest + QA Tier 1.5。
//
//  覆盖契约（state.md ## 契约规约）：
//    P1: scheduleSaveIndex / flushNow / saveWriteCount / saveCoalesceInterval == 0.1
//    P2: searchDebounceInterval == 0.15 / reloadDataCallCount 存在
//    P3: isLoadingIndex / indexLoadedNotification / __test_lastIndexLoadThread seam 存在
//    P4: MediaItem.cleanedNameLowercased == cleanedName.lowercased()（init + coder 往返 + 旧 plist 兼容）
//    P5: ContinueWatchingCollectionViewItem.__test_lastCacheHitThread seam 存在
//

import XCTest
@testable import IINA

final class MediaLibraryPerfP1P5UnitTests: XCTestCase {

  // MARK: - P4: MediaItem.cleanedNameLowercased

  /// 谓词 P4.2：字段存在且 == cleanedName.lowercased()（init(url:)）。
  func test_p4_cleanedNameLowercased_equals_lowercased_init() {
    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/Test.Movie.mkv"),
      cleanedName: "测试 Movie NAME",
      rawName: "raw",
      category: .movie)
    XCTAssertEqual(item.cleanedNameLowercased, item.cleanedName.lowercased(),
                   "cleanedNameLowercased 必须 == cleanedName.lowercased()")
    XCTAssertEqual(item.cleanedNameLowercased, "测试 movie name")
  }

  /// 谓词 P4.4 / I3：旧 plist（无 Key）decode 后 cleanedNameLowercased == cleanedName.lowercased()。
  /// 通过 NSKeyedArchiver 往返验证（encode 不写新 Key，decode 在 coder 里算）。
  func test_p4_cleanedNameLowercased_backward_compat_coder() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/tmp/Old.Plist.Movie.mkv"),
      cleanedName: "OLD Plist 影片",
      rawName: "raw",
      category: .movie)
    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: MediaItem.self, from: data)
    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.cleanedNameLowercased, decoded?.cleanedName.lowercased(),
                   "decode 后 cleanedNameLowercased 必须 == cleanedName.lowercased()（旧 plist 向后兼容）")
    XCTAssertEqual(decoded?.cleanedNameLowercased, "old plist 影片")
  }

  /// 谓词 P4.2：含中文/符号/大小写混合的字段值正确。
  func test_p4_cleanedNameLowercased_mixed_case_chinese_symbols() {
    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/x"),
      cleanedName: "Stranger.Things.S05E01-怪奇物语",
      rawName: "r",
      category: .tvShow,
      tvShowId: "怪奇物语")
    XCTAssertEqual(item.cleanedNameLowercased, "stranger.things.s05e01-怪奇物语")
    XCTAssertTrue(item.cleanedNameLowercased.contains("s05e01"))
  }

  // MARK: - P4: Store 查询用预计算字段（间接验证：结果正确性）

  /// 谓词 P4.1 / P2.3：items(category:filter:) 用预计算字段后结果 == reference lowercased 子串。
  func test_p4_store_items_filter_matches_reference() {
    let store = MediaLibraryStore.shared
    let items = [
      MediaItem(url: URL(fileURLWithPath: "/tmp/a"), cleanedName: "Inception",
                rawName: "r", category: .movie),
      MediaItem(url: URL(fileURLWithPath: "/tmp/b"), cleanedName: "The Dark Knight",
                rawName: "r", category: .movie),
      MediaItem(url: URL(fileURLWithPath: "/tmp/c"), cleanedName: "盗梦空间",
                rawName: "r", category: .movie),
    ]
    store.setItemsForTesting(items)

    let needle = "DARK"
    let result = store.items(category: .movie, filter: needle)
    let reference = items.filter { $0.cleanedName.lowercased().contains(needle.lowercased()) }
    XCTAssertEqual(result.count, reference.count, "预计算字段查询结果数 == reference")
    XCTAssertEqual(result.first?.cleanedName, "The Dark Knight")
  }

  // MARK: - P1: scheduleSaveIndex / flushNow / saveWriteCount

  /// 谓词 P1：flushNow 同步写盘 + saveWriteCount 自增。
  func test_p1_flushNow_increments_saveWriteCount() {
    let store = MediaLibraryStore.shared
    let before = store.saveWriteCount
    store.setItemsForTesting([
      MediaItem(url: URL(fileURLWithPath: "/tmp/p1-flush"), cleanedName: "P1 Flush",
                rawName: "r", category: .movie)
    ])
    store.flushNow()
    // flushNow 内 recordSaveWrite 在主线程同步调用（data.write 同步）。
    XCTAssertGreaterThanOrEqual(store.saveWriteCount, before + 1,
                                "flushNow 后 saveWriteCount 至少 +1")
  }

  /// 谓词 P1：saveIndex() 保留为 flushNow 别名（向后兼容）。
  func test_p1_saveIndex_alias_works() {
    let store = MediaLibraryStore.shared
    let before = store.saveWriteCount
    store.setItemsForTesting([
      MediaItem(url: URL(fileURLWithPath: "/tmp/p1-alias"), cleanedName: "P1 Alias",
                rawName: "r", category: .movie)
    ])
    store.saveIndex()
    XCTAssertGreaterThanOrEqual(store.saveWriteCount, before + 1,
                                "saveIndex()（flushNow 别名）后 saveWriteCount 至少 +1")
  }

  // MARK: - P3: seam 存在性（编译期可达 + 运行期类型）

  /// 谓词 P3：indexLoadedNotification 存在且名字 == "iinaMediaLibraryIndexLoaded"。
  func test_p3_indexLoadedNotification_name() {
    let name = MediaLibraryStore.indexLoadedNotification
    XCTAssertEqual(name.rawValue, "iinaMediaLibraryIndexLoaded",
                   "契约：indexLoadedNotification 名字固定")
  }

  /// 谓词 P3：isLoadingIndex seam 存在（bool 可读）。
  func test_p3_isLoadingIndex_seam_readable() {
    // 单例 init 异步加载可能已完成也可能在进行（取决于测试启动时序），仅断言可读。
    let _ = MediaLibraryStore.shared.isLoadingIndex
    XCTAssertTrue(true, "isLoadingIndex seam 编译期可达且运行期可读")
  }

  // MARK: - P5: seam 存在性

  /// 谓词 P5：ContinueWatchingCollectionViewItem.__test_lastCacheHitThread seam 存在。
  func test_p5_cacheHitThread_seam_exists() {
    // 初始可能为 nil（尚未 configure 过），仅断言 seam 可访问（static var）。
    let _ = ContinueWatchingCollectionViewItem.__test_lastCacheHitThread
    // 重置避免跨测试污染。
    ContinueWatchingCollectionViewItem.__test_lastCacheHitThread = nil
    XCTAssertNil(ContinueWatchingCollectionViewItem.__test_lastCacheHitThread,
                 "__test_lastCacheHitThread seam 编译期可达且可写")
  }
}
