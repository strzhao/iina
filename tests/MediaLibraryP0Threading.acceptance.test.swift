//
//  MediaLibraryP0Threading.acceptance.test.swift
//  iina
//
//  红队验收测试 — Phase 0 线程模型修复（黑盒/契约视角，基于 ## 契约规约 + ## 验收场景）
//
//  覆盖验收谓词：
//    ACC-P0-1-mainthread [det-machine]: probeMetadata 完成后 item 的
//      width/height/duration/year 被填充，且字段写入发生在主线程。
//    ACC-P0-3-concurrent [det-machine]: probeQueue 并发限宽
//      maxConcurrentOperationCount == 4。
//    ACC-throttle-coalesce [det-machine]: 100ms 内 N>1 条
//      metadataProbedNotification → 重配至多一次/窗口（不丢：每个 item 最终被重配）。
//    ACC-preserve-防循环（回归）：probedKeys 命中的 item 不再发起 probe。
//
//  覆盖契约：
//    C1  MediaItem var 字段只在主线程被读写（经 applyProbeResult 主线程应用）
//    C1b 后台块禁止读写任何 MediaItem var 字段（仅可读 item.url.path 等 let）
//    C4  probeQueue.maxConcurrentOperationCount == 4
//    C5  metadataProbed 经 pendingProbedItems 集合 + 100ms tail-coalesce（不丢更新）
//    保持契约: probedKeys/probingKeys 防 probe 循环
//
//  需声明的 @testable internal seam（蓝队实现须满足）：
//    - MediaLibraryStore.probeQueue: OperationQueue（或等价只读访问器）
//    - MediaLibraryStore.probedKeys: Set<String>（读，验证防循环）
//    - MediaLibraryStore.probingKeys: Set<String>（读，验证发起 probe）
//    - MediaLibraryStore.probeKey(for item: MediaItem) -> String（或暴露 key 计算逻辑）
//    - MediaLibraryViewController.reconfigureCallCount: Int（或可观测的重配计数 seam）
//
//  样本策略：probeMetadata 依赖 FFmpegController.probeVideoInfo（真实 avformat IO），
//  独立 typecheck 不链接 app。运行期测试用 /tmp 临时可解码 mp4（需 ffmpeg 生成，
//  与 MediaThumbnailer.acceptance.test.swift 同策略）。字段填充为"契约编码"，
//  GUI 实际验证由 QA marker 完成。
//

import XCTest
@testable import iina

final class MediaLibraryP0ThreadingAcceptanceTests: XCTestCase {

  // MARK: - 辅助：构造测试 MediaItem

  /// 构造一个未 probe 的 MediaItem（所有可探测字段为 nil）
  private func makeUnprobedItem(name: String = "测试电影",
                                urlPath: String = "/tmp/iina_p0_probe_\(UUID().uuidString).mkv") -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: urlPath),
      cleanedName: name,
      rawName: name + ".1080p",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: nil,        // 待 probe 填充
      thumbnailPath: nil,
      year: nil,            // 待 probe 填充
      width: nil,           // 待 probe 填充
      height: nil,          // 待 probe 填充
      videoCodec: nil,      // 待 probe 填充
      bitrate: nil          // 待 probe 填充
    )
  }

  /// 生成一个可解码的样本 mp4（probeMetadata 需要真实可读文件）
  /// 与 MediaThumbnailer.acceptance.test.swift 同策略
  private func makeSampleVideo() -> URL? {
    let url = URL(fileURLWithPath: "/tmp/iina_p0_sample_\(UUID().uuidString).mp4")
    let task = Process()
    task.launchPath = "/opt/homebrew/bin/ffmpeg"
    if !FileManager.default.isExecutableFile(atPath: task.launchPath!) {
      task.launchPath = "/usr/local/bin/ffmpeg"
    }
    guard FileManager.default.isExecutableFile(atPath: task.launchPath!) else { return nil }
    task.arguments = ["-f", "lavfi", "-i", "color=c=green:s=320x240:d=2", "-y", url.path]
    task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    task.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
      try task.run()
      task.waitUntilExit()
      return url
    } catch {
      return nil
    }
  }

  override func tearDown() {
    // 清理 /tmp/iina_p0_* 临时文件
    let tmp = FileManager.default
    if let entries = try? tmp.contentsOfDirectory(atPath: "/tmp") {
      for e in entries where e.hasPrefix("iina_p0_") {
        try? tmp.removeItem(atPath: "/tmp/" + e)
      }
    }
    super.tearDown()
  }

  // MARK: - ACC-P0-1-mainthread：probe 后字段填充 + 主线程写入

  /// 谓词: ACC-P0-1-mainthread
  /// WHEN probeMetadata(for:) 完成一个 item（真实可解码文件），
  /// THEN 该 item 的 width/height/duration/year 至少其一被填充（非 nil），
  ///      且字段写入发生在主线程。
  ///
  /// observe: 字段非 nil + 通知 payload 携带 item + applyProbeResult 主线程断言。
  /// CONTRACT_SEAM: 需 MediaLibraryStore.metadataProbedNotification（已 internal static）。
  /// 此测试用真实可解码 mp4 验证端到端字段填充（C1）；主线程写入（C1b）由通知到达线程
  /// + applyProbeResult 契约保证（独立 typecheck 不验证运行时线程，由 TSan/QA 补充）。
  func test_probeMetadata_fills_fields_after_completion() {
    guard let sampleURL = makeSampleVideo() else {
      // ffmpeg 不可用——降级为契约存在性断言（不静默跳过）
      // CONTRACT_NOTE: probeMetadata 接口必须存在且可调用
      let item = makeUnprobedItem()
      MediaLibraryStore.shared.setItemsForTesting([item])
      // 仅验证 API 存在（不实际 probe 无效文件）
      XCTAssertNotNil(MediaLibraryStore.metadataProbedNotification,
                     "metadataProbedNotification 通知名必须存在（C5 契约）")
      return
    }

    let item = makeUnprobedItem(urlPath: sampleURL.path)
    MediaLibraryStore.shared.setItemsForTesting([item])

    // 监听通知（验证 item 被携带 + 到达线程）
    let notificationExp = expectation(description: "metadataProbedNotification fired")
    var notifiedItem: MediaItem?
    var notifiedOnMain = false
    let observer = NotificationCenter.default.addObserver(
      forName: MediaLibraryStore.metadataProbedNotification,
      object: nil, queue: .main
    ) { note in
      notifiedItem = note.object as? MediaItem
      notifiedOnMain = Thread.isMainThread
      notificationExp.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    // 触发 probe（内部异步，等通知）
    MediaLibraryStore.shared.probeMetadata(for: item)
    wait(for: [notificationExp], timeout: 20.0)

    // 断言 1: 通知携带正确 item（C5 payload 契约）
    XCTAssertTrue(notifiedItem === item || notifiedItem?.url == item.url,
                 "metadataProbedNotification 必须携带被 probe 的 item（C5 契约）")

    // 断言 2: 字段至少其一被填充（C1：probe 结果被应用）
    // 真实 mp4 应至少有 width/height/duration 之一（FFmpegController.probeVideoInfo 解析）
    let hasWidth = (item.width != nil)
    let hasHeight = (item.height != nil)
    let hasDuration = (item.duration != nil)
    let hasYear = (item.year != nil)
    XCTAssertTrue(hasWidth || hasHeight || hasDuration || hasYear,
                 "probe 完成后 width/height/duration/year 至少其一必须被填充（C1），"
                 + "实际 width=\(String(describing: item.width)) height=\(String(describing: item.height)) "
                 + "duration=\(String(describing: item.duration)) year=\(String(describing: item.year))")

    // 断言 3（C1b 弱形式）：通知在主线程到达（applyProbeResult 主线程应用的间接证据）
    // 严格 TSan 数据竞争验证由 Instruments TSan 补充；此处验证通知投递线程。
    XCTAssertTrue(notifiedOnMain,
                 "metadataProbedNotification 必须在主线程投递（applyProbeResult 主线程应用的证据，C1/C1b）")
  }

  // MARK: - ACC-P0-1-mainthread（边界）：width/height 一致性

  /// 谓词: ACC-P0-1-mainthread 边界
  /// 当 width 被填充时，height 也应被填充（probe 结果是分辨率对，不应只填一半）
  /// 防止蓝队"只填 width 不填 height"的残缺实现。
  func test_probeMetadata_width_height_consistency() {
    guard let sampleURL = makeSampleVideo() else {
      // ffmpeg 不可用——跳过（降级）
      XCTAssertTrue(true, "ffmpeg 不可用，降级跳过 width/height 一致性验证")
      return
    }
    let item = makeUnprobedItem(urlPath: sampleURL.path)
    MediaLibraryStore.shared.setItemsForTesting([item])

    let exp = expectation(description: "probe completion")
    let observer = NotificationCenter.default.addObserver(
      forName: MediaLibraryStore.metadataProbedNotification,
      object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(observer) }

    MediaLibraryStore.shared.probeMetadata(for: item)
    wait(for: [exp], timeout: 20.0)

    // 若 width 非 nil 则 height 必须非 nil（反之亦然）——分辨率成对
    if item.width != nil {
      XCTAssertNotNil(item.height,
                     "width 已填充时 height 必须同时填充（分辨率成对，C1），"
                     + "width=\(String(describing: item.width)) height=\(String(describing: item.height))")
    }
    if item.height != nil {
      XCTAssertNotNil(item.width,
                     "height 已填充时 width 必须同时填充（分辨率成对，C1）")
    }
  }

  // MARK: - ACC-P0-3-concurrent：probeQueue 并发限宽 == 4

  /// 谓词: ACC-P0-3-concurrent
  /// WHEN 多个 item 入 probe，
  /// THEN probeQueue.maxConcurrentOperationCount == 4（C4）。
  ///
  /// CONTRACT_SEAM（红队声明，蓝队须满足）:
  ///   需 @testable internal 读 probeQueue.maxConcurrentOperationCount。
  ///   方式 A（首选）: 蓝队把 probeQueue 改 internal（或 private→internal）。
  ///   方式 B（等价）: 蓝队提供 `internal var probeQueueMaxConcurrent: Int {
  ///       probeQueue.maxConcurrentOperationCount }`。
  /// 本测试声明方式 B（不破坏封装），蓝队二选一实现。
  func test_probeQueue_maxConcurrent_is_four() {
    // SEAM_ASSERTION: 红队声明需要以下 internal seam 之一：
    //   (A) MediaLibraryStore.probeQueue: OperationQueue（internal）
    //   (B) MediaLibraryStore.probeQueueMaxConcurrent: Int（internal computed）
    // 蓝队实现时任选其一。测试编译期要求至少一个存在；运行期断言 == 4。
    //
    // 当前以方式 B 书写（最小侵入）；若蓝队选方式 A，将下行 probeQueueMaxConcurrent
    // 替换为 probeQueue.maxConcurrentOperationCount 即可。

    let maxConcurrent = MediaLibraryStore.shared.probeQueueMaxConcurrent
    XCTAssertEqual(maxConcurrent, 4,
                   "probeQueue.maxConcurrentOperationCount 必须 == 4（C4，P0-3 并发限宽），"
                   + "实际: \(maxConcurrent)。serial(1) 会卡死整条队列；>4 加剧通知风暴。")
  }

  // MARK: - ACC-P0-3-concurrent（时序）：慢 probe 不阻塞其他 probe

  /// 谓词: ACC-P0-3-concurrent 时序
  /// WHEN 一个慢 probe（大文件/慢 NAS）进行中，THEN 其他 item 的 probe 仍能完成。
  /// observe: 并发提交 2 个 probe，至少 2 个通知到达（不互相阻塞）。
  ///
  /// 注意：serial queue 下 2 个 probe 也会最终完成（只是排队），此测试验证
  /// "不串行阻塞"的弱形式——至少都能完成（不死锁）。严格时序（并行加速）由 QA marker。
  func test_probeQueue_slow_probe_does_not_block_others() {
    guard let sample1 = makeSampleVideo(), let sample2 = makeSampleVideo() else {
      XCTAssertTrue(true, "ffmpeg 不可用，降级跳过慢 probe 不阻塞测试")
      return
    }
    let item1 = makeUnprobedItem(name: "慢A", urlPath: sample1.path)
    let item2 = makeUnprobedItem(name: "慢B", urlPath: sample2.path)
    MediaLibraryStore.shared.setItemsForTesting([item1, item2])

    let exp1 = expectation(description: "probe1 done")
    let exp2 = expectation(description: "probe2 done")
    var done1 = false
    var done2 = false
    let observer = NotificationCenter.default.addObserver(
      forName: MediaLibraryStore.metadataProbedNotification,
      object: nil, queue: .main
    ) { note in
      if let it = note.object as? MediaItem {
        if it.url == item1.url { done1 = true; exp1.fulfill() }
        if it.url == item2.url { done2 = true; exp2.fulfill() }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    // 并发提交 2 个 probe
    MediaLibraryStore.shared.probeMetadata(for: item1)
    MediaLibraryStore.shared.probeMetadata(for: item2)

    // 两者都必须完成（C4：慢 probe 不阻塞其他）
    wait(for: [exp1, exp2], timeout: 40.0)
    XCTAssertTrue(done1 && done2,
                  "并发提交 2 个 probe，两者都必须完成（C4 不串行阻塞），"
                  + "done1=\(done1) done2=\(done2)")
  }

  // MARK: - ACC-throttle-coalesce：100ms 窗口内多通知合并为至多一次重配

  /// 谓词: ACC-throttle-coalesce
  /// WHEN 100ms 内到达 N(>1) 条 metadataProbedNotification，
  /// THEN reconfigureVisibleItems() 在该窗口内至多执行一次（C5），
  ///      且每个到达 item 最终被重配（不丢更新）。
  ///
  /// CONTRACT_SEAM（红队声明，蓝队须满足）:
  ///   需 @testable internal 可观测的重配计数。方式:
  ///     (A) MediaLibraryViewController.reconfigureCallCount: Int（internal，每次 +1）
  ///     (B) MediaLibraryViewController.pendingProbedItems: Set<MediaItem>（internal，读状态）
  ///   本测试声明方式 A（直接计数）；蓝队须在 reconfigureVisibleItems(for:) 内自增。
  ///
  /// 黑盒观测：快速发 N 条通知（模拟 probe 并发完成），等 200ms（>100ms 窗口），
  /// 断言 reconfigureCallCount 增量 <= 1（单窗口合并）。
  /// 不丢更新：发 N 条不同 item 的通知，flush 后所有 item 在 pendingProbedItems 被清空
  /// （即都被重配过）。
  func test_metadataProbed_coalesces_burst_within_100ms_window() {
    // SEAM_ASSERTION: 需 MediaLibraryViewController 实例 + reconfigureCallCount internal seam。
    // VC 构造需要 NSCollectionView 等 AppKit 依赖，独立 typecheck 可行，运行期需 app 环境。
    // 此测试作为契约编码；运行期由 QA 在真实 VC 上验证。
    let vc = MediaLibraryViewController()

    let initialCount = vc.reconfigureCallCount

    // 模拟 100ms 内 5 条通知（不同 item，模拟并发 probe 完成）
    let items: [MediaItem] = (0..<5).map { i in
      makeUnprobedItem(name: "节流\(i)")
    }
    vc.displayedItems = items  // 让它们 visible

    for item in items {
      NotificationCenter.default.post(
        name: MediaLibraryStore.metadataProbedNotification,
        object: item
      )
    }

    // 等待超过 coalesce 窗口（100ms tail-coalesce + 余量）
    let exp = expectation(description: "coalesce window elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
    wait(for: [exp], timeout: 2.0)

    let finalCount = vc.reconfigureCallCount
    let delta = finalCount - initialCount

    // C5 核心断言：5 条通知 → 至多 1 次重配（单窗口合并）
    XCTAssertLessThanOrEqual(delta, 1,
                             "100ms 窗口内 5 条 metadataProbedNotification 必须合并为至多 1 次 "
                             + "reconfigureVisibleItems（C5 节流），实际增量: \(delta)")
    XCTAssertGreaterThanOrEqual(delta, 0, "重配计数不得为负")
  }

  // MARK: - ACC-throttle-coalesce（不丢更新）：每个 item 最终被重配

  /// 谓词: ACC-throttle-coalesce 不丢更新（C5 不变量）
  /// WHEN N 条不同 item 的通知在 100ms 内到达，
  /// THEN 每个 item 都在某次 flush 被重配（pendingProbedItems 最终清空，无残留）。
  ///
  /// CONTRACT_SEAM: 需 pendingProbedItems internal（读状态）或 reconfigureVisibleItems
  /// 被调用时传入的 changed 集合可观测。本测试声明 pendingProbedItems 读 seam。
  func test_metadataProbed_does_not_drop_any_item() {
    let vc = MediaLibraryViewController()
    let items: [MediaItem] = (0..<3).map { i in
      makeUnprobedItem(name: "不丢\(i)")
    }
    vc.displayedItems = items

    // 快速发 3 条
    for item in items {
      NotificationCenter.default.post(
        name: MediaLibraryStore.metadataProbedNotification,
        object: item
      )
    }

    // 等 flush 完成（>100ms）
    let exp = expectation(description: "flush complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
    wait(for: [exp], timeout: 2.0)

    // C5 不丢更新：flush 后 pendingProbedItems 应为空（全部已重配）
    // SEAM_ASSERTION: 需 pendingProbedItems internal 读 seam。
    XCTAssertEqual(vc.pendingProbedItems.count, 0,
                  "100ms 窗口 flush 后 pendingProbedItems 必须清空（C5 不丢更新：每个 item 最终被重配），"
                  + "残留: \(vc.pendingProbedItems.count)")
  }

  // MARK: - ACC-throttle-coalesce（跨窗口）：间隔 >100ms 的通知各自触发

  /// 谓词: ACC-throttle-coalesce 跨窗口
  /// WHEN 两条通知间隔 >100ms，THEN 各自触发一次重配（不被错误合并）。
  /// 防止蓝队"永久节流只重配一次"的退化实现。
  func test_metadataProbed_separate_windows_each_reconfigures() {
    let vc = MediaLibraryViewController()
    let initialCount = vc.reconfigureCallCount

    let item1 = makeUnprobedItem(name: "窗口1")
    let item2 = makeUnprobedItem(name: "窗口2")
    vc.displayedItems = [item1, item2]

    // 第 1 条
    NotificationCenter.default.post(
      name: MediaLibraryStore.metadataProbedNotification, object: item1)
    let exp1 = expectation(description: "window1 flush")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp1.fulfill() }
    wait(for: [exp1], timeout: 2.0)

    let afterFirst = vc.reconfigureCallCount

    // 间隔 >100ms 再发第 2 条
    NotificationCenter.default.post(
      name: MediaLibraryStore.metadataProbedNotification, object: item2)
    let exp2 = expectation(description: "window2 flush")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp2.fulfill() }
    wait(for: [exp2], timeout: 2.0)

    let afterSecond = vc.reconfigureCallCount

    // 两次窗口各触发至少 1 次（防止永久节流退化）
    XCTAssertGreaterThan(afterSecond - initialCount, 0,
                        "跨 100ms 窗口的第二条通知必须触发重配（防止永久节流退化）")
    XCTAssertGreaterThanOrEqual(afterSecond - afterFirst, 1,
                               "第二个 100ms 窗口必须至少触发 1 次重配，"
                               + "实际增量: \(afterSecond - afterFirst)")
  }

  // MARK: - ACC-preserve-防循环（回归）：probedKeys 命中不再 probe

  /// 谓词: ACC-preserve-防循环（回归）
  /// WHEN 一个 item 已在 probedKeys（key 命中），
  /// THEN probeMetadata(for:) 不再发起 probe（probingKeys 不新增）。
  ///
  /// CONTRACT_SEAM（红队声明，蓝队须满足）:
  ///   需 @testable internal 读 probedKeys / probingKeys。
  ///   方式 A: probedKeys/probingKeys 改 internal（Set<String>）。
  ///   方式 B: 提供 `func isProbed(_ item: MediaItem) -> Bool` / `func isProbing(_:) -> Bool`。
  ///   方式 C: 提供 `func probeKey(for item: MediaItem) -> String`（暴露 key 计算）。
  ///   本测试声明方式 C + 方式 A/B（测试用 key 比对）。
  ///
  /// 保持契约: probedKeys/probingKeys 防 probe 循环（probedKeys 命中即跳过）。
  func test_probedKeys_hit_skips_reprobe() {
    guard let sampleURL = makeSampleVideo() else {
      XCTAssertTrue(true, "ffmpeg 不可用，降级跳过防循环测试")
      return
    }
    let item = makeUnprobedItem(urlPath: sampleURL.path)
    MediaLibraryStore.shared.setItemsForTesting([item])

    // 第一次 probe（应发起并完成）
    let exp1 = expectation(description: "first probe")
    let observer1 = NotificationCenter.default.addObserver(
      forName: MediaLibraryStore.metadataProbedNotification,
      object: nil, queue: .main
    ) { _ in exp1.fulfill() }
    defer { NotificationCenter.default.removeObserver(observer1) }
    MediaLibraryStore.shared.probeMetadata(for: item)
    wait(for: [exp1], timeout: 20.0)

    // 第一次完成后，probedKeys 应包含 item 的 key
    let key = MediaLibraryStore.shared.probeKey(for: item)
    XCTAssertTrue(MediaLibraryStore.shared.probedKeys.contains(key),
                 "首次 probe 完成后 probedKeys 必须包含该 item 的 key（防循环基础），"
                 + "key=\(key)")

    // 统计第二次 probe 前后的通知数（防循环：不应再发通知）
    var secondNotificationCount = 0
    let observer2 = NotificationCenter.default.addObserver(
      forName: MediaLibraryStore.metadataProbedNotification,
      object: nil, queue: .main
    ) { _ in secondNotificationCount += 1 }
    defer { NotificationCenter.default.removeObserver(observer2) }

    // 第二次 probe 同一 item（probedKeys 已命中）
    MediaLibraryStore.shared.probeMetadata(for: item)

    // 等足够时间（若有 probe 应发通知）
    let exp2 = expectation(description: "wait for possible second probe")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp2.fulfill() }
    wait(for: [exp2], timeout: 3.0)

    // 保持契约断言：probedKeys 命中 → 不再 probe → 不再发通知
    XCTAssertEqual(secondNotificationCount, 0,
                  "probedKeys 命中的 item 不应再次 probe（保持契约：防 probe 循环），"
                  + "实际收到 \(secondNotificationCount) 条通知")

    // probingKeys 也不应残留（未发起新 probe）
    XCTAssertFalse(MediaLibraryStore.shared.probingKeys.contains(key),
                  "probedKeys 命中的 item 不应进入 probingKeys（未发起新 probe）")
  }

  // MARK: - ACC-preserve-防循环（probingKeys 防重入）

  /// 谓词: 保持契约 probingKeys 防重入
  /// WHEN 一个 item 正在 probe（probingKeys 命中），
  /// THEN 不重复发起（probingKeys 不重复 insert，避免 stampede）。
  func test_probingKeys_prevents_duplicate_probe() {
    guard let sampleURL = makeSampleVideo() else {
      XCTAssertTrue(true, "ffmpeg 不可用，降级跳过 probingKeys 测试")
      return
    }
    let item = makeUnprobedItem(urlPath: sampleURL.path)
    MediaLibraryStore.shared.setItemsForTesting([item])
    let key = MediaLibraryStore.shared.probeKey(for: item)

    // 发起 probe（异步，未完成）
    MediaLibraryStore.shared.probeMetadata(for: item)

    // 立即查 probingKeys（probe 进行中）
    // 注意：时序敏感，probingKeys.insert 在 probeMetadata 入口同步执行
    XCTAssertTrue(MediaLibraryStore.shared.probingKeys.contains(key),
                 "probe 发起后 probingKeys 必须立即包含 key（防重入基础）")

    // 等完成
    let exp = expectation(description: "probe complete")
    let observer = NotificationCenter.default.addObserver(
      forName: MediaLibraryStore.metadataProbedNotification,
      object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(observer) }
    wait(for: [exp], timeout: 20.0)

    // 完成后 probingKeys 应移除（移交 probedKeys）
    XCTAssertFalse(MediaLibraryStore.shared.probingKeys.contains(key),
                  "probe 完成后 probingKeys 必须移除该 key（移交 probedKeys）")
  }

  // MARK: - Mutation-Survival 自检

  /// No-op 自检：metadataProbedNotification 通知名非空且稳定
  /// 防止蓝队改通知名破坏现有观察者。
  func test_notification_names_stable() {
    XCTAssertEqual(MediaLibraryStore.metadataProbedNotification.rawValue,
                   "iinaMediaLibraryMetadataProbed",
                   "metadataProbedNotification 通知名必须稳定（保持契约：不改名）")
    XCTAssertEqual(MediaLibraryStore.scannedNotification.rawValue,
                   "iinaMediaLibraryScanned",
                   "scannedNotification 通知名必须稳定（保持契约：不改名）")
  }
}
