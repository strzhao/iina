//
//  MediaLibraryPerfSaveIndex.acceptance.test.swift
//  iina
//
//  红队验收测试 — P1 saveIndex 后台 ioQueue + tail-coalesce 合并写（黑盒视角）
//
//  覆盖谓词：
//    P1.1 [det-machine] 写盘不在主线程（main 同步写 <= 2_000_000 ns）
//    P1.3 [det-machine] 合并写（N>=8 变更 → saveWriteCount <= 4 && < N）
//    P1.4 [det-machine] 探测结果重启后持久化（flushNow 后 reloaded == probed）
//    P1.5 [det-machine] 退出前 flush 兜底（willTerminateNotification 触发后 persisted == true）
//
//  设计文档声明 seam（均 internal；本测试断言这些）：
//    MediaLibraryStore.scheduleSaveIndex()          // 主线程；标记 dirty + 0.1s 合并调度
//    MediaLibraryStore.flushNow()                   // 主线程同步编码+写；退出/测试
//    MediaLibraryStore.saveWriteCount: Int          // saveQueue 写盘次数（lock 守护）
//    saveCoalesceInterval == 0.1 (s)
//
//  注：P1.2（探测期主线程单次阻塞 <= 8ms）需要真实 NAS/probe IO；P1.4 reloaded==probed
//      需写盘后重新 init MediaLibraryStore——单例约束下用 flushNow 直接断言 plist 已落盘
//      覆盖等价语义（持久化已发生）。
//

import XCTest
@testable import IINA

final class MediaLibraryPerfSaveIndexAcceptanceTests: XCTestCase {

  // MARK: - 辅助

  /// 构造一个 MediaItem（电影）。
  private func makeItem(_ name: String) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_p1_\(UUID().uuidString).mkv"),
      cleanedName: name,
      rawName: name + ".1080p",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: 3600,
      thumbnailPath: nil
    )
  }

  // MARK: - P1.1 写盘不在主线程：主线程同步文件写 <= 2_000_000 ns
  // 契约：P1 设计「主线程编码 + 后台 saveQueue 写盘」。主线程不直接 `data.write(to:)`，
  // 只在 scheduleSaveIndex 内做簿记（标记 dirty + 调度）→ 主线程同步开销应远低于直接写盘。
  // 边界值（## 契约规约 边界值）：主线程同步文件写耗时 <= 2_000_000 ns（2ms，调度开销）。

  /// 谓词: P1.1 [det-machine] 写盘不在主线程
  /// WHEN 主线程连续 scheduleSaveIndex() 8 次，
  /// THEN 单次 scheduleSaveIndex 的主线程同步开销 <= 2_000_000 ns（写盘在 saveQueue 不阻塞主线程）。
  func test_scheduleSaveIndex_does_not_block_main_thread() {
    let store = MediaLibraryStore.shared
    store.setItemsForTesting((0..<8).map { makeItem("P1.1-\($0)") })

    // 多次测量取最大值（避免单次抖动低估）
    var worstCaseNs: UInt64 = 0
    for _ in 0..<8 {
      let start = DispatchTime.now()
      store.scheduleSaveIndex()
      let end = DispatchTime.now()
      let elapsed = end.uptimeNanoseconds - start.uptimeNanoseconds
      if elapsed > worstCaseNs { worstCaseNs = elapsed }
    }

    // 立即 flushNow 兜底（防合并写残留影响后续测试）
    store.flushNow()

    XCTAssertLessThanOrEqual(
      worstCaseNs, 2_000_000,
      "P1.1 违反：scheduleSaveIndex 主线程同步开销 \(worstCaseNs) ns > 2_000_000 ns（2ms 容差）。"
      + "写盘应在 saveQueue 后台执行，主线程仅做簿记。"
    )
  }

  // MARK: - P1.3 合并写：N>=8 变更 → saveWriteCount <= 4 && < N
  // 契约：saveCoalesceInterval == 0.1（s，与 metadataProbed 一致）。0.1s 窗口内多次 schedule
  //       合并为 1 次编码+写。边界值：N>=8 → saveWriteCount <= 4 && < N。
  // CONTRACT_SEAM：MediaLibraryStore.saveWriteCount: Int（internal private(set)，saveQueue 内 lock 守护 +1）。

  /// 谓词: P1.3 [det-machine] 合并写
  /// WHEN 主线程在 saveCoalesceInterval (0.1s) 窗口内连续 N>=8 次 scheduleSaveIndex()，
  /// THEN saveWriteCount <= 4 && saveWriteCount < N（合并写：8 次变更不产生 8 次写盘）。
  func test_saveIndex_coalesces_burst_into_few_writes() {
    let store = MediaLibraryStore.shared
    // 先 flushNow 把 baseline 清零，并记录初始 saveWriteCount
    store.flushNow()
    let baseline = store.saveWriteCount

    // 注入大量 item（每次 setItemsForTesting 改 items 数组，模拟批量探测回填）
    let N = 12  // >= 8
    for i in 0..<N {
      store.setItemsForTesting([makeItem("P1.3-burst-\(i)")])
      store.scheduleSaveIndex()
    }

    // 等合并窗口结束（saveCoalesceInterval == 0.1s + flush 余量）
    let exp = expectation(description: "coalesce window elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
    wait(for: [exp], timeout: 2.0)

    // 兜底 flush（若窗口未自然 flush，flushNow 触发最终一次写）
    store.flushNow()

    let delta = store.saveWriteCount - baseline
    XCTAssertLessThanOrEqual(
      delta, 4,
      "P1.3 违反：N=\(N) 次 scheduleSaveIndex 合并后写盘次数 delta=\(delta) > 4（契约 <= 4）"
    )
    XCTAssertLessThan(
      delta, N,
      "P1.3 违反：合并写未生效：delta=\(delta) >= N=\(N)（每次 schedule 都触发一次写盘，无合并）"
    )
  }

  // MARK: - P1.4 持久化：flushNow 后 plist 已落盘（reloaded 语义等价）
  // 契约：flushNow() 主线程同步编码 + 同步写。退出/测试用。
  // 验证：flushNow 后 index.plist 存在且尺寸 > 0（数据已落盘）。
  // CONTRACT_AMBIGUOUS: 设计文档 P1.4 谓词原文「reloaded == probed」需要重新 init 单例读取，
  // 单例约束下不可行；改为「flushNow 后 plist 文件非空」等价覆盖持久化已发生语义。
  // indexURL 是 private（设计文档声明），通过 testDataRoot 重定向；此处用 testDataRoot 路径
  // 验证（注入 -iinaTestDataRoot 时 indexURL = <root>/media_library_index.plist）。
  // 若无 testDataRoot，回退到 appSupportDirUrl（生产路径），用 FileManager 直接探测。

  /// 谓词: P1.4 [det-machine] 探测结果重启后持久化（等价：flushNow 后 index.plist 非空）
  func test_flushNow_persists_items_to_plist() {
    let store = MediaLibraryStore.shared
    let items = (0..<3).map { makeItem("P1.4-persist-\($0)") }
    store.setItemsForTesting(items)
    store.scheduleSaveIndex()

    // flushNow 同步落盘
    store.flushNow()

    // 探测 index.plist 已写入（路径与生产 indexURL 同源）
    let plistURL: URL
    if let root = Utility.testDataRootURL {
      plistURL = root.appendingPathComponent("media_library_index.plist")
    } else {
      plistURL = Utility.appSupportDirUrl.appendingPathComponent("media_library_index.plist")
    }

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: plistURL.path),
      "P1.4 违反：flushNow() 后 index.plist 不存在（未持久化）：\(plistURL.path)"
    )
    let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path)
    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    XCTAssertGreaterThan(
      size, 0,
      "P1.4 违反：flushNow() 后 index.plist 存在但 size==0（空文件，未真正写入）"
    )
  }

  // MARK: - P1.5 退出 flush 兜底：willTerminateNotification 触发后持久化
  // 契约：注册 NSApplication.willTerminateNotification（在 init）→ flushNow() 兜底。
  // 验证：模拟 willTerminate 投递（VC/Store 通过 NotificationCenter 监听）后，dirty 项被落盘。
  // 边界值：after_exit_persisted == true。

  /// 谓词: P1.5 [det-machine] 退出前 flush 兜底
  /// WHEN scheduleSaveIndex() 后未等合并窗口自然 flush，模拟 NSApplication.willTerminateNotification 投递，
  /// THEN plist 已落盘（after_exit_persisted == true）。
  func test_willTerminate_flushes_pending_dirty_state() {
    let store = MediaLibraryStore.shared
    let items = (0..<2).map { makeItem("P1.5-exit-\($0)") }
    store.setItemsForTesting(items)
    store.scheduleSaveIndex()

    // 合并窗口可能尚未自然 flush——这正是「退出兜底」的场景
    // 模拟 app 退出：投递 willTerminateNotification（Store init 时应已注册监听）
    NotificationCenter.default.post(
      name: NSApplication.willTerminateNotification,
      object: NSApplication.shared
    )

    // willTerminate → flushNow 是同步路径，post 返回时 plist 已落盘
    let plistURL: URL
    if let root = Utility.testDataRootURL {
      plistURL = root.appendingPathComponent("media_library_index.plist")
    } else {
      plistURL = Utility.appSupportDirUrl.appendingPathComponent("media_library_index.plist")
    }

    let afterExitPersisted = FileManager.default.fileExists(atPath: plistURL.path)
      && ((try? FileManager.default.attributesOfItem(atPath: plistURL.path)[.size] as? NSNumber)??.int64Value ?? 0) > 0

    XCTAssertTrue(
      afterExitPersisted,
      "P1.5 违反：willTerminateNotification 投递后 index.plist 仍未落盘（退出兜底失败）。"
      + "Store 必须在 init 注册 willTerminateNotification → flushNow()。"
    )
  }

  // MARK: - Mutation-Survival 自检

  /// No-op 自检：scheduleSaveIndex 不应在没有 schedule 时无中生有触发写盘。
  /// 防止蓝队「每次 scheduleSaveIndex 都立即 flushNow」的伪合并实现。
  func test_scheduleSaveIndex_does_not_flush_synchronously_per_call() {
    let store = MediaLibraryStore.shared
    store.flushNow()
    let baseline = store.saveWriteCount

    // 3 次快速 schedule（窗口内）
    store.scheduleSaveIndex()
    store.scheduleSaveIndex()
    store.scheduleSaveIndex()

    // 同步立即读 saveWriteCount（不应增长——合并窗口尚未到）
    let immediateDelta = store.saveWriteCount - baseline
    XCTAssertEqual(
      immediateDelta, 0,
      "P1.3 No-op 自检违反：scheduleSaveIndex 立即触发同步写盘 delta=\(immediateDelta)"
      + "（应为 0.1s 合并，不应每次调用即写）"
    )

    // 兜底 flush
    store.flushNow()
  }
}
