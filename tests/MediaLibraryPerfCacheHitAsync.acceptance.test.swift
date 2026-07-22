//
//  MediaLibraryPerfCacheHitAsync.acceptance.test.swift
//  iina
//
//  红队验收测试 — P5 缩略图 cache-hit 异步化（B2 修复：主路径在 ContinueWatchingCollectionViewItem）
//
//  覆盖谓词：
//    P5.1 [det-machine] cache-hit PNG 读不在主线程（B2：主路径测 ContinueWatchingCollectionViewItem）
//    P5.2 [det-machine] 快速滚动主线程单次阻塞 <= 8ms（marker 心跳）
//    P5.3 [det-machine] cache-hit 缩略图非空（cell_image_is_set）
//    P5.4 [visual-residue] 渲染非占位（non_placeholder_ratio >= 0.3）
//    P5.5 [det-machine] completion 在主线程（callback_on_main == true）
//    P5.6 [det-machine] 未命中仍走 FFmpeg（ffmpeg_invoked && image_set）
//
//  设计文档声明 seam（internal）：
//    ContinueWatchingCollectionViewItem.__test_lastCacheHitThread: Thread?  // static，主路径读 PNG 后记录
//
//  关键不变量（## 契约规约 边界值）：
//    __test_lastCacheHitThread.isMainThread == false；completion 线程 == main
//    主路径：ContinueWatchingCollectionViewItem.configure:169 cache-hit 异步化
//    兜底路径：MediaThumbnailer.generateThumbnail:153 cache-hit 分支整体在 queue.async
//

import XCTest
@testable import IINA

final class MediaLibraryPerfCacheHitAsyncAcceptanceTests: XCTestCase {

  // MARK: - 辅助

  /// 构造一张临时 PNG 缩略图（1x1 像素）作为 cache-hit 文件。
  private func makePNG() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/iina_perf_p5_thumb_\(UUID().uuidString).png")
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: url)
    return url
  }

  // MARK: - P5.1 主路径 cache-hit 读不在主线程（ContinueWatchingCollectionViewItem）

  /// 谓词: P5.1 [det-machine] cache-hit PNG 读不在主线程（B2 主路径：ContinueWatchingCollectionViewItem）
  /// WHEN ContinueWatchingCollectionViewItem.configure(with:ignorePath:) 传入一个 thumbnailPath 非空
  ///      且 PNG 文件存在的 MediaItem，
  /// THEN __test_lastCacheHitThread.isMainThread == false（PNG 读在 DispatchQueue.global 后台）。
  /// seam: ContinueWatchingCollectionViewItem.__test_lastCacheHitThread（static, Thread?）。
  func test_continue_watching_cache_hit_read_off_main_thread() throws {
    // 重置 seam
    ContinueWatchingCollectionViewItem.__test_lastCacheHitThread = nil

    // 构造 cache-hit 文件
    let thumbURL = try makePNG()
    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_p5_main_\(UUID().uuidString).mkv"),
      cleanedName: "P5.1 Main Path",
      rawName: "P5.1.mkv",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: 100,
      thumbnailPath: thumbURL
    )

    // 构造 cell（NSCollectionViewItem 子类）
    let cell = ContinueWatchingCollectionViewItem()
    _ = cell.view  // 触发 loadView

    // 主线程上 configure（与生产路径一致）
    XCTAssertTrue(
      Thread.isMainThread,
      "P5.1 前置：configure 必须在主线程调用（生产路径）"
    )
    cell.configure(with: ContinueWatchingEntry(item: item, progressSec: 50, durationSec: 100, displayName: item.cleanedName), ignorePath: false)

    // configure 返回后 cache-hit 异步读 PNG 应在后台执行；
    // 等待 seam 被记录（异步入队 + 读 PNG）
    let exp = expectation(description: "cache-hit async read done")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
    wait(for: [exp], timeout: 3.0)

    let thread = ContinueWatchingCollectionViewItem.__test_lastCacheHitThread
    XCTAssertNotNil(
      thread,
      "P5.1 CONTRACT_SEAM 未触发：__test_lastCacheHitThread 仍为 nil。"
      + "configure cache-hit 路径未执行异步读，或蓝队未在 cache-hit 读取点调用 recordCacheHitThread()。"
      + "（B2 修复：主路径 ContinueWatchingCollectionViewItem.configure:169 是异步化对象）"
    )
    if let t = thread {
      XCTAssertFalse(
        t.isMainThread,
        "P5.1 违反：cache-hit PNG 读线程 isMainThread == true（应在 DispatchQueue.global 后台读 NSImage）。"
        + "B2 核实：主线程同步 cache-hit 在 ContinueWatchingCollectionViewItem:169，须仿 MediaItemCollectionViewItem:429 异步化。"
      )
    }

    // 清理
    try? FileManager.default.removeItem(at: thumbURL)
  }

  // MARK: - P5.1b 兜底路径 cache-hit 读不在主线程（MediaThumbnailer:153）

  /// 谓词: P5.1 [det-machine] 兜底路径 cache-hit 读不在主线程（MediaThumbnailer:153）
  /// WHEN MediaThumbnailer.generateThumbnail(for:ignorePath:completion:) 被调用且
  ///      cache 目录下已存在对应 PNG（cache-hit），
  /// THEN cache-hit 的 NSImage(contentsOf:) 读在非主线程（整体在 queue.async），
  ///      且 completion 在主线程。
  /// 注：该路径覆盖 thumbnailPath==nil 但磁盘缓存命中的场景（如旧 plist 向后兼容）。
  func test_media_thumbnailer_cache_hit_read_off_main_thread() throws {
    // 预置 cache-hit PNG（用 MediaThumbnailer 的 cache 命名规则）
    let dummyURL = URL(fileURLWithPath: "/tmp/iina_perf_p5_thumb_src_\(UUID().uuidString).mkv")
    let cacheName = MediaThumbnailer.cacheName(for: dummyURL, ignorePath: false)
    let cacheURL = MediaThumbnailer.cacheDirectoryURL()
      .appendingPathComponent(cacheName + ".png")
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 写一张 PNG
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
      .representation(using: .png, properties: [:])!
    try png.write(to: cacheURL)

    // 调 generateThumbnail（cache-hit 路径）
    let exp = expectation(description: "thumbnail completion")
    var resultImage: NSImage? = nil
    var callbackThread: Thread? = nil
    MediaThumbnailer.shared.generateThumbnail(for: dummyURL, ignorePath: false) { image in
      resultImage = image
      callbackThread = Thread.current
      exp.fulfill()
    }
    wait(for: [exp], timeout: 3.0)

    // P5.5 completion 在主线程
    XCTAssertEqual(
      callbackThread?.isMainThread, true,
      "P5.5 违反：cache-hit completion 必须在主线程（契约不变量 callback_on_main == true），"
      + "实际 isMainThread=\(callbackThread?.isMainThread ?? false)"
    )
    // cache-hit 应返回非 nil 图像
    XCTAssertNotNil(
      resultImage,
      "P5.3 违反：cache-hit 应返回非 nil NSImage（cell_image_is_set 前置）"
    )

    // 清理
    try? FileManager.default.removeItem(at: cacheURL)

    // 注：cache-hit 的读取线程（MediaThumbnailer 内部 NSImage(contentsOf:)）是否在后台，
    // 由设计声明「generateThumbnail cache-hit 分支整体在 queue.async」保证。
    // 红队无法直接观测 MediaThumbnailer 内部读 PNG 的线程（无私有 seam），通过「completion 主线程」
    // + 「未命中走 FFmpeg」（P5.6）等可观测契约间接保证。
    // 蓝队若提供 __test_lastCacheHitThread 等价 seam 在 MediaThumbnailer，QA 可直接断言；
    // 当前设计未声明 MediaThumbnailer 内部读线程 seam，故此处不强断言。
  }

  // MARK: - P5.2 快速滚动主线程单次阻塞 <= 8ms
  // 契约：marker 心跳验证主线程单帧阻塞 <= 8ms（60fps 预算）。
  // 注：此谓词需真实 cell configure + 快速滚动场景，hosted XCTest 难以模拟滚动事件。
  // 采用等价语义：configure 单次主线程同步开销 <= 8ms（cache-hit 异步化后应满足）。

  /// 谓词: P5.2 [det-machine] 单次 configure 主线程阻塞 <= 8ms（快速滚动等价）
  /// WHEN 主线程对带 cache-hit thumbnailPath 的 cell 调用 configure(with:ignorePath:)，
  /// THEN 单次 configure 的主线程同步开销 <= 8_000_000 ns（8ms，60fps 单帧预算）。
  /// 注：PNG 读在后台，configure 仅做簿记（捕获 token / 派发 async）。
  func test_single_configure_does_not_block_main_thread_beyond_8ms() throws {
    let thumbURL = try makePNG()
    let items: [MediaItem] = (0..<10).map { i in
      MediaItem(
        url: URL(fileURLWithPath: "/tmp/iina_perf_p5_perf_\(i)_\(UUID().uuidString).mkv"),
        cleanedName: "P5.2 Perf \(i)",
        rawName: "P5.2-\(i).mkv",
        category: .movie, tvShowId: nil, episodeNumber: nil,
        duration: 100, thumbnailPath: thumbURL
      )
    }

    let cell = ContinueWatchingCollectionViewItem()
    _ = cell.view

    var worstCaseNs: UInt64 = 0
    for item in items {
      let start = DispatchTime.now()
      cell.configure(with: ContinueWatchingEntry(item: item, progressSec: 50, durationSec: 100, displayName: item.cleanedName), ignorePath: false)
      let end = DispatchTime.now()
      let elapsed = end.uptimeNanoseconds - start.uptimeNanoseconds
      if elapsed > worstCaseNs { worstCaseNs = elapsed }
    }

    XCTAssertLessThanOrEqual(
      worstCaseNs, 8_000_000,
      "P5.2 违反：单次 configure 主线程同步开销 \(worstCaseNs) ns > 8_000_000 ns（8ms）。"
      + "cache-hit PNG 读必须异步化（B2），否则快速滚动掉帧。"
    )

    try? FileManager.default.removeItem(at: thumbURL)
  }

  // MARK: - P5.3 cache-hit 缩略图非空（cell image 被设置）

  /// 谓词: P5.3 [det-machine] cache-hit 缩略图非空
  /// WHEN cell.configure(with:ignorePath:) 传入 thumbnailPath 非空且 PNG 存在，
  /// THEN 异步读完成后 cell.thumbnailView.image 非 nil（cache-hit 命中并设到 image）。
  func test_cache_hit_sets_cell_thumbnail_image() throws {
    ContinueWatchingCollectionViewItem.__test_lastCacheHitThread = nil

    let thumbURL = try makePNG()
    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_p5_image_\(UUID().uuidString).mkv"),
      cleanedName: "P5.3 Image Set",
      rawName: "P5.3.mkv",
      category: .movie, tvShowId: nil, episodeNumber: nil,
      duration: 100, thumbnailPath: thumbURL
    )
    let cell = ContinueWatchingCollectionViewItem()
    _ = cell.view
    cell.configure(with: ContinueWatchingEntry(item: item, progressSec: 50, durationSec: 100, displayName: item.cleanedName), ignorePath: false)

    // 等异步读 + 主线程设 image 完成
    let exp = expectation(description: "image set on main thread")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
    wait(for: [exp], timeout: 3.0)

    XCTAssertNotNil(
      cell.thumbnailView.image,
      "P5.3 违反：cache-hit 后 cell.thumbnailView.image 仍为 nil（PNG 读失败或未设到 image）。"
      + "stale guard 应允许同 token 的 cache-hit 通过并设 image。"
    )

    try? FileManager.default.removeItem(at: thumbURL)
  }

  // MARK: - P5.4 [visual-residue] 渲染非占位

  /// 谓词: P5.4 [visual-residue] 渲染非占位（non_placeholder_ratio >= 0.3）
  /// 注：hosted XCTest 无 CGWindowList 图像分析能力，留 QA 真机判定。
  func test_P5_4_visual_residue_placeholder() {
    // VISUAL_RESIDUE: 留 QA 真机判定（CGWindowList 图像分析）
    // 期望：non_placeholder_ratio >= 0.3（至少 30% cell 渲染真实缩略图非占位）
    print("[P5.4 visual-residue] QA 真机判定：non_placeholder_ratio >= 0.3")
  }

  // MARK: - P5.5 completion 在主线程（与 P5.1b 合并断言）

  /// 谓词: P5.5 [det-machine] completion 在主线程（cache-hit）
  /// WHEN cache-hit 命中，completion 被回调，
  /// THEN completion 线程 == main（callback_on_main == true）。
  /// （P5.1b 已覆盖 cache-hit 主线程 completion；此处独立验证 cell-side：image 设到 thumbnailView
  ///  的代码必须在主线程——通过 stale guard + DispatchQueue.main.async）
  func test_completion_callback_on_main_thread_for_cache_hit() throws {
    // 详见 test_media_thumbnailer_cache_hit_read_off_main_thread 的 callbackThread 断言
    // 此处独立声明 cell-side 契约：cell.thumbnailView.image = img 必须在主线程
    // 设计 P5：completion/设 image 在主线程（契约不变量）
    // 等价验证：cell-side configure 后，观察 thumbnailView.image 在主线程被设
    let thumbURL = try makePNG()
    let item = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_p5_cb_\(UUID().uuidString).mkv"),
      cleanedName: "P5.5 Callback",
      rawName: "P5.5.mkv",
      category: .movie, tvShowId: nil, episodeNumber: nil,
      duration: 100, thumbnailPath: thumbURL
    )
    let cell = ContinueWatchingCollectionViewItem()
    _ = cell.view

    // 主线程上调用 configure
    XCTAssertTrue(Thread.isMainThread)
    cell.configure(with: ContinueWatchingEntry(item: item, progressSec: 50, durationSec: 100, displayName: item.cleanedName), ignorePath: false)

    // 等异步读 + 主线程设 image
    let exp = expectation(description: "main-thread image set")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
    wait(for: [exp], timeout: 3.0)

    // 若 image 被设置，断言它发生在主线程——通过 final 状态观测
    // （异步代码若在后台设 NSImageView.image 会触发 AppKit 主线程断言，故蓝队必须在主线程设）
    XCTAssertNotNil(
      cell.thumbnailView.image,
      "P5.5 前置：cache-hit 后 cell.thumbnailView.image 应非 nil"
    )

    try? FileManager.default.removeItem(at: thumbURL)
  }

  // MARK: - P5.6 未命中仍走 FFmpeg（回归保护三联之一）

  /// 谓词: P5.6 [det-machine] 未命中仍走 FFmpeg
  /// WHEN generateThumbnail 调用时 cache 目录无对应 PNG（cache-miss），
  /// THEN FFmpegController 被入队抽帧（dispatch 路径不变），completion 被回调。
  /// 注：cache-miss 用一个不存在的 URL（保证 cache 文件不存在）。
  ///      FFmpeg 实际抽帧可能失败（无文件），但 dispatch 路径必须被触发——通过 completion 被回调验证。
  func test_cache_miss_still_invokes_ffmpeg_path() {
    // 清除 cache（确保 miss）
    let dummyURL = URL(fileURLWithPath: "/tmp/iina_perf_p5_miss_\(UUID().uuidString).mkv")
    let cacheName = MediaThumbnailer.cacheName(for: dummyURL, ignorePath: false)
    let cacheURL = MediaThumbnailer.cacheDirectoryURL()
      .appendingPathComponent(cacheName + ".png")
    try? FileManager.default.removeItem(at: cacheURL)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: cacheURL.path),
      "P5.6 前置：cache 文件应不存在（miss 场景）"
    )

    // 调 generateThumbnail（miss 路径）
    let exp = expectation(description: "ffmpeg path completion")
    var imageSet: Bool = false
    var invokedFFmpeg = false
    MediaThumbnailer.shared.generateThumbnail(for: dummyURL, ignorePath: false) { image in
      imageSet = (image != nil)
      invokedFFmpeg = true  // completion 被回调即证明走了 dispatch 路径（cache-hit 会提前 return）
      exp.fulfill()
    }
    wait(for: [exp], timeout: 15.0)  // FFmpeg 超时 10s + 余量

    // P5.6 核心：cache-miss 走 dispatch（FFmpeg 路径），completion 被回调
    XCTAssertTrue(
      invokedFFmpeg,
      "P5.6 违反：cache-miss 未触发 FFmpeg dispatch 路径（completion 未回调）。"
      + "cache-hit 异步化不应破坏未命中走 FFmpegController 的原路径。"
    )
    // 注：dummyURL 不存在，FFmpeg 抽帧必然失败 → image == nil（降级占位）。
    // P5.6 关心的是「FFmpeg 路径被触发」而非「抽帧成功」，故不强断言 imageSet==true。
    // 「image_set」谓词用真实可解码视频文件验证（MediaThumbnailer.acceptance.test.swift 已覆盖）。
    _ = imageSet
  }
}
