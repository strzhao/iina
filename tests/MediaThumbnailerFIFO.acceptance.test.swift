//
//  MediaThumbnailerFIFO.acceptance.test.swift
//  iina
//
//  红队验收测试 — Phase 0 缩略图 FIFO 不丢任务（黑盒/契约视角，基于 ## 契约规约 + ## 验收场景）
//
//  覆盖验收谓词：
//    ACC-P0-2-no-drop [det-machine]: K(>poolSize=3) 个不同未缓存请求提交、slot 被占时，
//      每个 completion 恰被调用一次（count == K）。
//    ACC-P0-2-fifo-drain [det-machine]: slot 释放后 pending 排空
//      （由 no-drop 间接覆盖：全部 completion 最终触发）。
//
//  覆盖契约：
//    C2  MediaThumbnailer.generateThumbnail 的 completion 恰被调用一次（main 线程）；
//        池满时请求入 FIFO pending 队列等待，不因池满丢弃，不做 dedup。
//    C3  slot 释放时（生成完成/timeout）在 lock.unlock() 之后触发 dispatchNextPending()；
//        startJob 恒在锁外调用（防 NSLock 重入死锁）；pending 队列持续排空。
//
//  需声明的 @testable internal seam（蓝队实现须满足）：
//    - 无（本组测试纯黑盒，通过 generateThumbnail public API + completion 计数观测）。
//    - 可选增强: MediaThumbnailer.pendingCount: Int（若蓝队提供，可白盒验证 FIFO drain）。
//
//  CONTRACT_AMBIGUITY（API 形式）:
//    现有 MediaThumbnailer.acceptance.test.swift 用 `MediaThumbnailer.generateThumbnail(...)`
//    （static 形式）；但 Explore 探测实际签名为实例方法
//    `func generateThumbnail(for url: URL, ignorePath: Bool, completion: ...)` + `shared` 单例。
//    本测试按**实例方法 + shared** 书写（与实际签名一致）。
//    若蓝队同时提供 static 便捷封装（转发到 shared），两套调用等价；否则以实例方法为准。
//
//  样本策略：setUp 用 ffmpeg 生成 K 个可解码 mp4（K > poolSize=3），每个独立 URL
//  避免缓存命中（C2 不做 dedup，但缓存命中会短路——测试用唯一 URL 避开）。
//  负路径：不存在的文件（completion 须回调 nil，仍算"被调用一次"——不丢）。
//

import XCTest
@testable import iina

final class MediaThumbnailerFIFOAcceptanceTests: XCTestCase {

  /// 缩略图缓存目录
  private var cacheDir: URL {
    Utility.thumbnailCacheURL.appendingPathComponent("media_thumbnails", isDirectory: true)
  }

  /// 正路径样本视频（setUp 生成，K 个）
  private var sampleVideos: [URL] = []

  /// 测试用 K（必须 > poolSize=3 才能触发 pending 队列）
  /// 用 8 既 >3 又不过大（避免单测过慢）
  private let k = 8

  override func setUp() {
    super.setUp()
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    // 生成 K 个独立样本视频（每个不同 URL，避免缓存命中）
    for i in 0..<k {
      let url = URL(fileURLWithPath: "/tmp/iina_fifo_\(i)_\(UUID().uuidString).mp4")
      let task = Process()
      task.launchPath = "/opt/homebrew/bin/ffmpeg"
      if !FileManager.default.isExecutableFile(atPath: task.launchPath!) {
        task.launchPath = "/usr/local/bin/ffmpeg"
      }
      guard FileManager.default.isExecutableFile(atPath: task.launchPath!) else { continue }
      task.arguments = ["-f", "lavfi", "-i", "color=c=blue:s=64x64:d=1", "-y", url.path]
      task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
      task.standardError = FileHandle(forWritingAtPath: "/dev/null")
      do {
        try task.run()
        task.waitUntilExit()
        sampleVideos.append(url)
      } catch {
        // 单个生成失败不中断（后续测试降级）
      }
    }
  }

  override func tearDown() {
    for url in sampleVideos {
      try? FileManager.default.removeItem(at: url)
    }
    sampleVideos.removeAll()
    super.tearDown()
  }

  // MARK: - 辅助：清理某 URL 的缓存（确保不命中）

  private func clearCache(for url: URL) {
    let md5 = Utility.mpvWatchLaterMd5(url, false)
    let cacheFile = cacheDir.appendingPathComponent("\(md5).png")
    try? FileManager.default.removeItem(at: cacheFile)
  }

  // MARK: - ACC-P0-2-no-drop：K>3 个请求，每个 completion 恰被调用一次

  /// 谓词: ACC-P0-2-no-drop
  /// WHEN K(=8 > poolSize=3) 个不同未缓存文件的缩略图请求被提交，
  ///      且 slot 被慢任务占住（3 个 slot 并发，K=8 必有 5 个入 pending），
  /// THEN 每个 completion 恰被调用一次（count == K），无因池满被丢弃。
  ///
  /// observe: completion 计数 == K（硬断言）。
  /// CONTRACT: C2 — completion 恰被调用一次；池满入 FIFO pending，不丢弃，不做 dedup。
  ///
  /// 核心防回归：修复前 dispatch 在 `attempt >= 4` 时直接 completion(nil) 丢任务，
  /// 大库慢 NAS 永久占位图。本测试断言"永不丢任务"。
  func test_no_drop_all_completions_called_when_pool_saturated() {
    XCTAssertGreaterThanOrEqual(sampleVideos.count, k,
                                "需要 ≥\(k) 个样本视频验证池满不丢，实际生成: \(sampleVideos.count)。"
                                + "请确保 ffmpeg 可用。")
    guard sampleVideos.count >= k else { XCTFail("样本不足"); return }

    // 清理所有样本缓存（确保未命中 → 真实进入 dispatch/pending）
    for url in sampleVideos.prefix(k) {
      clearCache(for: url)
    }

    let allDone = expectation(description: "all \(k) completions called")
    allDone.expectedFulfillmentCount = k

    // 计数（原子，completion 可能跨线程——但契约要求 main 线程；此处用 lock 保险）
    let counter = AtomicCounter()

    // 并发提交 K 个请求（瞬间提交，3 slot 立即满，其余入 pending）
    for url in sampleVideos.prefix(k) {
      MediaThumbnailer.shared.generateThumbnail(for: url, ignorePath: false) { _ in
        counter.increment()
        allDone.fulfill()
      }
    }

    // 给足时间（K=8，3 并发，单文件 ≤10s → 3 批约 30s，给 90s 余量覆盖慢 NAS 场景）
    wait(for: [allDone], timeout: 90.0)

    let finalCount = counter.value
    XCTAssertEqual(finalCount, k,
                   "FIFO 不变式破坏：提交 \(k) 个请求但只有 \(finalCount) 个 completion 被调用（C2）。"
                   + "池满时请求必须入 pending 队列等待，不得丢弃。缺失: \(k - finalCount) 个。")
  }

  // MARK: - ACC-P0-2-no-drop（含负路径）：不存在的文件 completion 也回调

  /// 谓词: ACC-P0-2-no-drop 负路径
  /// WHEN K 个请求中混入不存在的文件（负路径），
  /// THEN 这些请求的 completion 仍被调用一次（回调 nil），不被丢弃。
  /// 防止蓝队"负路径 fast-path 丢 completion"。
  func test_no_drop_even_for_missing_files() {
    // 构造 K 个不存在的文件 URL（每个唯一，避免 dedup）
    let missingURLs: [URL] = (0..<k).map { i in
      URL(fileURLWithPath: "/tmp/iina_fifo_missing_\(i)_\(UUID().uuidString).mkv")
    }

    let allDone = expectation(description: "all missing-file completions called")
    allDone.expectedFulfillmentCount = k
    let counter = AtomicCounter()

    for url in missingURLs {
      MediaThumbnailer.shared.generateThumbnail(for: url, ignorePath: false) { _ in
        counter.increment()
        allDone.fulfill()
      }
    }

    // 不存在文件应快速回调 nil（超时路径），给 30s 余量
    wait(for: [allDone], timeout: 60.0)

    XCTAssertEqual(counter.value, k,
                   "不存在的文件 completion 也必须被调用（C2 不丢任务），"
                   + "实际: \(counter.value)/\(k)。负路径不得 fast-path 丢弃。")
  }

  // MARK: - ACC-P0-2-fifo-drain：slot 释放后 pending 排空

  /// 谓词: ACC-P0-2-fifo-drain
  /// WHEN slot 释放（生成完成/timeout），THEN dispatchNextPending() 触发，
  ///      pending 队首被取出执行，最终 pending 为空。
  ///
  /// 黑盒间接验证（由 no-drop 覆盖）：
  ///   若 pending 不 drain，超额请求的 completion 永不触发 → no-drop 测试已硬断言。
  ///   此处用"两阶段"验证 drain 顺序：先发 poolSize 个占满，再发超额，验证超额最终完成。
  ///
  /// CONTRACT_SEAM（可选增强）:
  ///   若蓝队提供 `internal var pendingCount: Int`，可白盒断言 pending 最终 == 0。
  ///   本测试黑盒验证（completion 全触发 = pending 已 drain）。
  func test_fifo_drain_pending_empties_after_slot_release() {
    XCTAssertGreaterThanOrEqual(sampleVideos.count, k,
                                "需要 ≥\(k) 个样本验证 FIFO drain")
    guard sampleVideos.count >= k else { XCTFail("样本不足"); return }

    for url in sampleVideos.prefix(k) {
      clearCache(for: url)
    }

    let phase1 = expectation(description: "first batch (poolSize) drained")
    phase1.expectedFulfillmentCount = 3  // 先验证前 3 个（占满 slot）

    // 先发前 3 个（占满 pool）
    for url in sampleVideos.prefix(3) {
      MediaThumbnailer.shared.generateThumbnail(for: url, ignorePath: false) { _ in
        phase1.fulfill()
      }
    }
    wait(for: [phase1], timeout: 60.0)

    // slot 已释放（前 3 完成）。现在发剩余 K-3 个（应入 pending 后被 drain）
    let phase2 = expectation(description: "second batch drained from pending")
    phase2.expectedFulfillmentCount = k - 3
    for url in sampleVideos[3..<k] {
      MediaThumbnailer.shared.generateThumbnail(for: url, ignorePath: false) { _ in
        phase2.fulfill()
      }
    }
    wait(for: [phase2], timeout: 90.0)

    // 若 phase2 全完成 → pending 队列已被 drain（C3 dispatchNextPending 正常工作）
    // 若蓝队提供 pendingCount seam，可加强断言：
    // XCTAssertEqual(MediaThumbnailer.shared.pendingCount, 0, "pending 最终为空")
    XCTAssertTrue(true, "phase2 全完成 → pending 已 drain（C3）")
  }

  // MARK: - C2：completion 在主线程回调

  /// 谓词: C2 — completion 在 main 线程被调用
  /// 防止蓝队在后台线程回调 completion（主线程契约，UI 更新安全）。
  func test_completion_called_on_main_thread() {
    XCTAssertFalse(sampleVideos.isEmpty, "样本视频生成失败")
    guard let sample = sampleVideos.first else { XCTFail("无样本"); return }
    clearCache(for: sample)

    let exp = expectation(description: "main thread completion")
    var calledOnMain = false
    MediaThumbnailer.shared.generateThumbnail(for: sample, ignorePath: false) { _ in
      calledOnMain = Thread.isMainThread
      exp.fulfill()
    }
    wait(for: [exp], timeout: 30.0)

    XCTAssertTrue(calledOnMain,
                 "completion 必须在主线程回调（C2 main 线程契约），实际 isMainThread=\(calledOnMain)")
  }

  // MARK: - C3 防死锁：大量并发请求不死锁

  /// 谓词: C3 — 防死锁
  /// WHEN 大量（K*2）请求并发提交，THEN 无死锁（全部 completion 最终触发）。
  /// 防止蓝队 dispatchNextPending 在持锁状态下调用 startJob（NSLock 重入死锁）。
  ///
  /// 死锁表现为：部分 completion 永不触发（超时失败）。
  func test_no_deadlock_under_high_concurrency() {
    XCTAssertGreaterThanOrEqual(sampleVideos.count, 4,
                                "需要 ≥4 个样本验证无死锁")
    guard sampleVideos.count >= 4 else { XCTFail("样本不足"); return }

    // 用 4 个文件 × 每个重复 3 次 = 12 请求（C2 不做 dedup，重复 URL 也各入队）
    // 注意：C2 契约"不做 dedup"——重复 URL 的 completion 都要触发
    let totalRequests = 12
    let allDone = expectation(description: "all \(totalRequests) done, no deadlock")
    allDone.expectedFulfillmentCount = totalRequests

    for _ in 0..<3 {
      for url in sampleVideos.prefix(4) {
        // 不 clearCache——重复请求会命中缓存（fast-path completion），仍算"被调用"
        MediaThumbnailer.shared.generateThumbnail(for: url, ignorePath: false) { _ in
          allDone.fulfill()
        }
      }
    }

    // 死锁 → 部分永不完成 → 超时 fail
    wait(for: [allDone], timeout: 60.0)
    // 通过即无死锁（expectation 硬断言）
  }

  // MARK: - Mutation-Survival 自检

  /// Boundary 自检：单请求（K=1 < poolSize）正常完成
  /// 防止蓝队"pending 逻辑破坏单请求路径"。
  func test_single_request_completes_normally() {
    XCTAssertFalse(sampleVideos.isEmpty, "样本视频生成失败")
    guard let sample = sampleVideos.first else { XCTFail("无样本"); return }
    clearCache(for: sample)

    let exp = expectation(description: "single request")
    var gotImage: NSImage? = .none
    MediaThumbnailer.shared.generateThumbnail(for: sample, ignorePath: false) { image in
      gotImage = image
      exp.fulfill()
    }
    wait(for: [exp], timeout: 30.0)

    XCTAssertNotNil(gotImage,
                   "单个有效请求必须回调非 nil image（单请求路径不被 pending 逻辑破坏）")
  }
}

// MARK: - 原子计数器辅助

/// 线程安全计数器（completion 可能从不同线程回调时保险计数）
/// 注：契约要求 main 线程回调，但防蓝队违约用原子计数更稳。
private final class AtomicCounter {
  private let lock = NSLock()
  private var _value: Int = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }

  func increment() {
    lock.lock()
    _value += 1
    lock.unlock()
  }
}
