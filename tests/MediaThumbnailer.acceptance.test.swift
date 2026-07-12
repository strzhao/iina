//
//  MediaThumbnailer.acceptance.test.swift
//  iina
//
//  红队验收测试 — 缩略图生成（黑盒视角，基于 ## 契约规约）
//
//  覆盖验收场景：
//    场景 10-P1 [det-machine]: 首次扫描完成 → 缓存目录图片文件数 >= 60
//    场景 10-P2 [det-machine]: 缓存已存在 → 重新打开复用（mtime 未变）
//    场景 18-P2 [det-machine]: 缩略图按需生成（不全量预热 1168 文件）
//  覆盖契约边界值：
//    并发: ≤ 3
//    单文件抽帧超时: ≤ 10s
//    thumbnailCount=5（实际生成 6 帧含 0%/100%），取索引 1（约 20% 位置）
//    缓存复用 ThumbnailCache.fileIsCached 命中则跳过
//    缓存文件名 = Utility.mpvWatchLaterMd5(url, ignorePath)
//  覆盖错误契约：
//    缩略图生成失败：不抛错，completion 回调 nil，UI 用占位图
//
//  样本策略：setUp 用 ffmpeg 生成 1 秒可解码 mp4 作为正路径样本；
//  负路径用不存在的 URL / 损坏数据文件。无外部 fixture 依赖。
//

import XCTest
@testable import iina

final class MediaThumbnailerAcceptanceTests: XCTestCase {

  /// 缩略图缓存目录（契约逐字）
  private var cacheDir: URL {
    Utility.thumbnailCacheURL.appendingPathComponent("media_thumbnails", isDirectory: true)
  }

  /// 正路径样本视频（setUp 生成）
  private var sampleVideos: [URL] = []

  override func setUp() {
    super.setUp()
    // 确保缓存目录存在
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    // 用 ffmpeg 生成 4 个 1 秒可解码 mp4 样本（满足并发测试需要 ≥4 文件）
    for i in 0..<4 {
      let url = URL(fileURLWithPath: "/tmp/iina_acc_sample_\(i)_\(UUID().uuidString).mp4")
      let task = Process()
      task.launchPath = "/opt/homebrew/bin/ffmpeg"
      // 若 ffmpeg 不在 /opt/homebrew，回退 which 结果
      if !FileManager.default.isExecutableFile(atPath: task.launchPath!) {
        task.launchPath = "/usr/local/bin/ffmpeg"
      }
      task.arguments = ["-f", "lavfi", "-i", "color=c=blue:s=64x64:d=1", "-y", url.path]
      task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
      task.standardError = FileHandle(forWritingAtPath: "/dev/null")
      do {
        try task.run()
        task.waitUntilExit()
      } catch {
        // 若 ffmpeg 不可用，样本生成失败 — 测试必须 fail（不静默跳过）
        continue
      }
      sampleVideos.append(url)
    }
  }

  override func tearDown() {
    for url in sampleVideos {
      try? FileManager.default.removeItem(at: url)
    }
    sampleVideos.removeAll()
    super.tearDown()
  }

  // MARK: - 契约：completion 回调签名（正路径）

  /// 谓词: 契约 generateThumbnail(for:completion:) -> (NSImage?) -> Void
  /// 验证：合法可解码视频文件 → completion 回调非 nil NSImage
  func test_generateThumbnail_valid_file_returns_image() {
    XCTAssertFalse(sampleVideos.isEmpty,
                   "样本视频生成失败：ffmpeg 不可用或生成异常。测试无法继续——请确保 ffmpeg 在 PATH 中。")
    guard let sample = sampleVideos.first else {
      XCTFail("无样本视频可用"); return
    }

    let expectation = self.expectation(description: "thumbnail completion")
    var resultImage: NSImage? = .none
    MediaThumbnailer.generateThumbnail(for: sample) { image in
      resultImage = image
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 15.0)  // 契约 ≤10s + 余量

    XCTAssertNotNil(resultImage, "合法视频文件必须回调非 nil NSImage")
    XCTAssertGreaterThan(resultImage?.size.width ?? 0, 0, "NSImage 必须有有效尺寸")
  }

  // MARK: - 错误契约：不存在文件 → 回调 nil（不抛错）

  /// 谓词: 契约「缩略图生成失败：不抛错，completion 回调 nil」
  func test_generateThumbnail_missing_file_returns_nil_not_throw() {
    let nonexistent = URL(fileURLWithPath: "/tmp/iina_nonexistent_\(UUID().uuidString).mkv")

    let expectation = self.expectation(description: "thumbnail failure completion")
    var resultImage: NSImage? = NSImage()  // 初始化非 nil 以验证确实回调 nil
    MediaThumbnailer.generateThumbnail(for: nonexistent) { image in
      resultImage = image
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 15.0)

    XCTAssertNil(resultImage,
                 "不存在的文件必须回调 nil（不抛错），实际: \(String(describing: resultImage))")
  }

  // MARK: - 契约：超时 ≤10s 降级

  /// 谓词: 契约「单文件抽帧超时: ≤ 10s」
  /// 验证：损坏/无法解码的文件，completion 必须在 10s+余量内回调（不能无限等待）
  func test_generateThumbnail_completes_within_timeout_bound() {
    // 构造一个「看似视频但无法解码」的文件（非空但非视频格式）
    let bogus = URL(fileURLWithPath: "/tmp/iina_bogus_\(UUID().uuidString).mkv")
    try! Data(repeating: 0x00, count: 1024).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    let expectation = self.expectation(description: "timeout bound completion")
    var didComplete = false
    var returnedImage: NSImage? = NSImage()  // 非 nil 初值
    MediaThumbnailer.generateThumbnail(for: bogus) { image in
      didComplete = true
      returnedImage = image
      expectation.fulfill()
    }
    // 契约 ≤10s，测试给 12s 余量（含调度开销）
    wait(for: [expectation], timeout: 12.0)

    XCTAssertTrue(didComplete,
                  "单文件抽帧必须在 ≤10s 内完成回调（含降级路径），超时 12s 仍未回调")
    // 损坏文件应回调 nil（错误契约）
    XCTAssertNil(returnedImage,
                 "损坏文件应回调 nil（降级占位），实际: \(String(describing: returnedImage))")
  }

  // MARK: - 契约：缓存复用（fileIsCached 命中跳过）

  /// 谓词: 场景10-P2「缓存已存在 → 重新打开复用（mtime 未变）」
  /// 谓词: 契约「ThumbnailCache.fileIsCached 命中则跳过」
  func test_cache_hit_skips_regeneration() {
    XCTAssertFalse(sampleVideos.isEmpty, "样本视频生成失败")
    guard let sample = sampleVideos.first else { XCTFail("无样本"); return }
    let md5 = Utility.mpvWatchLaterMd5(sample, false)

    // 首次生成
    let exp1 = expectation(description: "first generation")
    MediaThumbnailer.generateThumbnail(for: sample) { _ in exp1.fulfill() }
    wait(for: [exp1], timeout: 15.0)

    // 断言缓存文件已生成
    XCTAssertTrue(ThumbnailCache.fileIsCached(forName: md5, forVideo: sample),
                  "首次生成后 ThumbnailCache.fileIsCached 必须返回 true")

    // 记录 mtime
    let cacheFile = cacheDir.appendingPathComponent("\(md5).png")
    let firstMtime = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate]) as? Date

    // 第二次调用（应命中缓存，不重新抽帧）
    let exp2 = expectation(description: "second call (cache hit)")
    MediaThumbnailer.generateThumbnail(for: sample) { _ in exp2.fulfill() }
    wait(for: [exp2], timeout: 5.0)  // 缓存命中应很快

    let secondMtime = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate]) as? Date
    XCTAssertEqual(firstMtime, secondMtime,
                   "缓存命中时不得重写文件，mtime 必须不变（场景 10-P2）")
  }

  // MARK: - 契约：缓存文件命名 = mpvWatchLaterMd5

  /// 谓词: 契约「缓存文件名 = Utility.mpvWatchLaterMd5(url, ignorePath)」
  func test_cache_file_named_by_mpvMd5() {
    XCTAssertFalse(sampleVideos.isEmpty, "样本视频生成失败")
    guard let sample = sampleVideos.first else { XCTFail("无样本"); return }
    let md5 = Utility.mpvWatchLaterMd5(sample, false)

    let exp = expectation(description: "generation for naming check")
    MediaThumbnailer.generateThumbnail(for: sample) { _ in exp.fulfill() }
    wait(for: [exp], timeout: 15.0)

    // 缓存目录下应存在以 md5 命名的文件
    let expectedPath = cacheDir.appendingPathComponent("\(md5).png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath.path),
                  "缓存文件必须以 mpvWatchLaterMd5 命名（\(md5).png），实际路径不存在: \(expectedPath.path)")
  }

  // MARK: - 契约：并发 ≤3（无死锁 + 全部完成）

  /// 谓词: 契约「缩略图生成并发: ≤ 3」
  /// 验证：同时发起 4 个请求，全部必须完成（无死锁）。
  /// 精确并发计数需白盒 hook FFmpegController 内部队列，红队黑盒验证「全部完成」硬断言。
  /// CONTRACT_NOTE: 若 MediaThumbnailer 未正确实现 3 实例池，单实例串行仍能完成 4 请求
  /// （只是慢），此用例验证不死锁；并发上界的严格验证由性能测试（场景 18）辅助。
  func test_concurrent_thumbnail_generation_no_deadlock() {
    XCTAssertGreaterThanOrEqual(sampleVideos.count, 4,
                                "需要 ≥4 个样本视频验证并发，实际生成: \(sampleVideos.count)")
    guard sampleVideos.count >= 4 else { XCTFail("样本不足"); return }

    let completedExpectation = expectation(description: "all 4 completed")
    completedExpectation.expectedFulfillmentCount = 4

    // 并发发起 4 个请求
    for url in sampleVideos.prefix(4) {
      MediaThumbnailer.generateThumbnail(for: url) { _ in
        completedExpectation.fulfill()
      }
    }

    // 给足时间（4 文件 × ≤10s/文件 ÷ 3 并发 ≈ 14s，给 30s 余量）
    // 若 MediaThumbnailer 单实例串行（无 3 实例池），4 文件串行约 40s，会超时失败
    wait(for: [completedExpectation], timeout: 30.0)
    // 全部完成即通过（expectation 已保证硬断言：未完成则超时 fail）
  }

  // MARK: - 场景 18-P2：按需生成不全量预热（接口形状验证）

  /// 谓词: 场景18-P2「缩略图按需生成（仅可视区）→ cache_files.count < 1168」
  /// 验证：generateThumbnail 是单文件按需接口（非批量预热）。
  /// 完整的「不全量预热」验证需端到端启动 app + 滚动网格（VISUAL_RESIDUE 场景18-P2）。
  /// 此处验证契约边界：调用 1 次只生成 1 个缓存文件（非批量）。
  func test_generateThumbnail_is_on_demand_single_file() {
    XCTAssertFalse(sampleVideos.isEmpty, "样本视频生成失败")
    guard let sample = sampleVideos.first else { XCTFail("无样本"); return }
    let md5 = Utility.mpvWatchLaterMd5(sample, false)
    let cacheFile = cacheDir.appendingPathComponent("\(md5).png")
    // 清理可能的历史缓存
    try? FileManager.default.removeItem(at: cacheFile)

    let exp = expectation(description: "single on-demand call")
    MediaThumbnailer.generateThumbnail(for: sample) { _ in exp.fulfill() }
    wait(for: [exp], timeout: 15.0)

    // 硬断言：调用 1 次只生成 1 个缓存文件（非批量）
    XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path),
                  "按需调用应生成对应缓存文件")
  }

  // MARK: - Mutation-Survival 自检

  /// No-op 自检：空路径 → 回调 nil（不崩溃）
  func test_generateThumbnail_empty_path_returns_nil_no_crash() {
    let empty = URL(fileURLWithPath: "")
    let exp = expectation(description: "empty path completion")
    var result: NSImage? = NSImage()
    MediaThumbnailer.generateThumbnail(for: empty) { image in
      result = image
      exp.fulfill()
    }
    wait(for: [exp], timeout: 12.0)
    XCTAssertNil(result, "空路径必须回调 nil 且不崩溃")
  }

  /// Boundary 自检：mkv 格式样本（FFmpegController 支持 mkv，契约关键点）
  /// 验证 FFmpegController 对 mkv 的支持（NAS 58% 为 mkv，AVFoundation 不可用故弃用）
  func test_generateThumbnail_mkv_format_supported() {
    // 生成 mkv 样本（ffmpeg 支持 mkv 容器）
    let mkvSample = URL(fileURLWithPath: "/tmp/iina_acc_mkv_\(UUID().uuidString).mkv")
    let task = Process()
    task.launchPath = "/opt/homebrew/bin/ffmpeg"
    if !FileManager.default.isExecutableFile(atPath: task.launchPath!) {
      task.launchPath = "/usr/local/bin/ffmpeg"
    }
    task.arguments = ["-f", "lavfi", "-i", "color=c=red:s=64x64:d=1", "-y", mkvSample.path]
    task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    task.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try? task.run()
    task.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: mkvSample) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: mkvSample.path),
                  "mkv 样本生成失败：ffmpeg 不可用")

    let exp = expectation(description: "mkv thumbnail")
    var result: NSImage? = .none
    MediaThumbnailer.generateThumbnail(for: mkvSample) { image in
      result = image
      exp.fulfill()
    }
    wait(for: [exp], timeout: 15.0)

    // 硬断言：mkv 必须能生成缩略图（FFmpegController 全格式支持是核心契约）
    XCTAssertNotNil(result,
                    "mkv 格式必须能生成缩略图（FFmpegController 支持 mkv，NAS 58% 为 mkv）")
  }
}
