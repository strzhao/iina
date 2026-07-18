//
//  MediaThumbnailer.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// Generates on-demand thumbnails for media library cards by reusing the built-in
/// `FFmpegController` (which links libavcodec/libavformat and supports mkv/ts/flv/avi —
/// AVFoundation is not viable as it does not support mkv, ~58% of NAS files).
///
/// `FFmpegController` is internally serial: `_queue.maxConcurrentOperationCount = 1` and
/// `generateThumbnailForFile:` begins by cancelling all operations on its queue, dropping any
/// in-flight older request on that instance. To achieve ≤3 concurrent thumbnail generations this
/// class maintains a pool of **3** `FFmpegController` instances and assigns each pending request to
/// a free one (round-robin). A single-file timeout of ≤10s degrades to a placeholder (completion
/// returns nil).
///
/// `thumbnailCount` is set to `5`, but `FFmpegController` generates `thumbnailCount + 1` frames
/// (the loop is `for i = 0; i <= thumbnailCount; i++`), i.e. 6 frames at 0%/20%/40%/60%/80%/100%.
/// We compute the **average luminance of each frame and pick the brightest** (avoids black
/// intro/outro screens — the cinematic card design amplifies such artifacts). If all frames are
/// near-black, we fall back to **index 1** (~20% position).
///
/// Caching reuses `ThumbnailCache`'s directory under `Utility.thumbnailCacheURL` in a
/// `media_thumbnails/` subdirectory. The cache key is
/// `Utility.mpvWatchLaterMd5(url, ignorePath)` (unchanged). The cached PNG is rendered at
/// `thumbWidth = 480` (up from 320) so the larger card display (~240pt) doesn't up-scale and blur.
final class MediaThumbnailer: NSObject {

  /// Shared singleton used by the media library UI.
  static let shared = MediaThumbnailer()

  /// Number of `FFmpegController` instances in the pool. Bounds concurrent generation to ≤3.
  private static let poolSize = 3

  /// Thumbnails to generate per file. FFmpegController emits `thumbnailCount + 1` frames.
  private static let thumbnailCount: Int = 5

  /// Fallback frame index when all candidate frames are near-black (avoids a black card).
  private static let fallbackFrameIndex: Int = 1

  /// Per-file generation timeout (seconds). On expiry, completion is called with nil.
  private static let timeout: TimeInterval = 10

  /// Thumbnail width in pixels. 480 matches the card display size (~240pt @ 2×) so the image
  /// is rendered at display resolution and not up-scaled.
  private static let thumbWidth: Int = 480

  /// Below this mean luminance (0–255), a frame is considered "near-black". When all candidate
  /// frames are below this, we fall back to `fallbackFrameIndex`.
  private static let blackLuminanceThreshold: Double = 12

  /// Directory under `Utility.thumbnailCacheURL` used for media-library thumbnails.
  static let cacheSubdir = "media_thumbnails"

  // MARK: Pool

  /// Each slot owns its `FFmpegController` and acts as its delegate, so `didGenerate` callbacks
  /// are routed to the exact slot that issued the request — fixing B2 (previously callbacks were
  /// matched by filename, which could hit the wrong slot when two slots processed the same URL).
  private final class PoolSlot: NSObject, FFmpegControllerDelegate {
    let controller: FFmpegController
    weak var owner: MediaThumbnailer?
    /// The job currently being processed by this slot, if any.
    var job: Job? = nil
    init(controller: FFmpegController, owner: MediaThumbnailer) {
      self.controller = controller
      self.owner = owner
      super.init()
      controller.delegate = self
    }
    func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int) {
      // Per-frame progress not needed for single-thumbnail media-library use.
    }
    func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool) {
      owner?.handleDidGenerate(slot: self, thumbnails: thumbnails, succeeded: succeeded)
    }
  }

  private final class Job {
    let url: URL
    let ignorePath: Bool
    let cacheName: String
    let cacheURL: URL
    let completion: (NSImage?) -> Void
    var timedOut: Bool = false
    init(url: URL, ignorePath: Bool, cacheName: String, cacheURL: URL, completion: @escaping (NSImage?) -> Void) {
      self.url = url
      self.ignorePath = ignorePath
      self.cacheName = cacheName
      self.cacheURL = cacheURL
      self.completion = completion
    }
  }

  private var slots: [PoolSlot] = []  // var: PoolSlot creation needs `self`, only valid after super.init
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "iina.media.thumbnailer", qos: .userInitiated)

  /// 累计已请求的缩略图数（C7 不变量计数器，`lock` 守护）。每次 `generateThumbnail` 入口 +1。
  /// **不 post 通知、不驱动 UI**：cell cache-hit :390 路径绕过 generateThumbnail，用计数
  /// 驱动 UI 会在多会话下失真（解 BLOCKER-1）；仅供 C7 不变量单测与未来扩展。
  private var totalRequestedCount: Int = 0
  /// 累计已完成（cache-hit / handleDidGenerate 成功 / 超时降级）的缩略图数（`lock` 守护）。
  /// 恒满足 `0 ≤ completedCount ≤ totalRequestedCount`。
  private var completedCount: Int = 0

  /// 池满时的 FIFO 待办队列（`lock` 守卫）。持有完整 `Job`（含 completion），slot 释放时由
  /// `dispatchNextPending()` 取出执行（P0-2）。**永不丢任务**：原 `dispatch` 的 `attempt>=4`
  /// 丢任务分支会让大库慢 NAS 永久占位图。**不做 dedup**：dedup 会让被丢请求的 completion
  /// 永不触发 → 永久占位；stale 回调由 cell 侧 `thumbnailToken` 防。
  private var pending: [Job] = []

  private override init() {
    Logger.log("MediaThumbnailer.init start, poolSize=\(MediaThumbnailer.poolSize)", level: .warning)
    super.init()
    var s: [PoolSlot] = []
    for _ in 0..<MediaThumbnailer.poolSize {
      let ctrl = FFmpegController()
      ctrl.thumbnailCount = MediaThumbnailer.thumbnailCount
      s.append(PoolSlot(controller: ctrl, owner: self))
    }
    self.slots = s
    let dir = MediaThumbnailer.cacheDirectoryURL()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  // MARK: Public API

  /// Generate (or load from cache) a thumbnail for `url`. Always calls `completion` on the main
  /// thread, with `nil` on failure/timeout (UI should show a placeholder).
  ///
  /// - Parameters:
  ///   - url: Video file URL.
  ///   - ignorePath: Value of `PlayerCore.ignorePathInWatchLaterConfig` — must match what
  ///     `HistoryController.add` uses so the cache key is consistent.
  ///   - completion: Called on main thread with the image, or nil.
  func generateThumbnail(for url: URL, ignorePath: Bool, completion: @escaping (NSImage?) -> Void) {
    Logger.log("MediaThumbnailer.generateThumbnail for \(url.lastPathComponent)", level: .warning)
    // 计数：入口 total++（lock 守护，C7）。先 total++ 再可能 completed++，保证无 completed 暂超 total 窗口。
    lock.lock()
    totalRequestedCount += 1
    lock.unlock()

    // P5 兜底路径：cache-hit 分支整体移入 queue.async（原 :153-160 在调用线程同步读 PNG）。
    // 经 cell.requestThumbnail→configure 链路时调用线程为主线程，同步读 PNG 卡滚动。
    // completion 仍显式回主线程（契约不变，P5.5）。
    queue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let cacheName = MediaThumbnailer.cacheName(for: url, ignorePath: ignorePath)
      let cacheURL = MediaThumbnailer.cacheDirectoryURL().appendingPathComponent(cacheName + ".png")
      Logger.log("  cacheDir=\(MediaThumbnailer.cacheDirectoryURL().path) dirExists=\(FileManager.default.fileExists(atPath: MediaThumbnailer.cacheDirectoryURL().path))", level: .warning)

      // Cache hit: load existing PNG（现已在 queue 线程）。
      if let img = NSImage(contentsOf: cacheURL) {
        // 计数：cache-hit 即完成（C7）。total 已在入口 +1，此处 completed++ 维持不变量。
        self.lock.lock()
        self.completedCount += 1
        self.lock.unlock()
        DispatchQueue.main.async { completion(img) }
        return
      }
      // 未命中仍走 dispatch（FFmpeg 抽帧，P5.6 回归保护）。
      self.dispatch(url: url, ignorePath: ignorePath, cacheName: cacheName, cacheURL: cacheURL, completion: completion)
    }
  }

  /// Clear all cached media-library thumbnails.
  static func clearCache() {
    let dir = cacheDirectoryURL()
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  /// 返回当前缩略图计数快照 `(total, completed)`（`lock` 内读，C7 不变量断言用）。
  /// 恒满足 `0 ≤ completed ≤ total`。**不 post 通知、不驱动 UI**——计数仅作不变量测试与
  /// 未来扩展；cell cache-hit 路径绕过 generateThumbnail，故计数不反映"屏幕上显示了多少张缩略图"。
  func thumbnailProgress() -> (total: Int, completed: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (totalRequestedCount, completedCount)
  }

  // MARK: Internals

  /// 构造 `Job` 并投递：有空 slot 则立即占位、锁外启动；否则入 FIFO pending 队列等待 slot 释放
  /// 驱动 dequeue。**不做 dedup**，**永不因池满丢任务**（P0-2 / C2）。
  private func dispatch(url: URL, ignorePath: Bool, cacheName: String, cacheURL: URL, completion: @escaping (NSImage?) -> Void) {
    let job = Job(url: url, ignorePath: ignorePath, cacheName: cacheName, cacheURL: cacheURL, completion: completion)
    var assigned: PoolSlot? = nil
    lock.lock()
    if let slot = slots.first(where: { $0.job == nil }) {
      slot.job = job
      assigned = slot
    } else {
      pending.append(job)
    }
    lock.unlock()
    // 恒锁外启动（startJob 内部会再 lock，NSLock 非递归，持锁调用必死锁）——C3。
    if let slot = assigned {
      startJob(on: slot, job: job)
    }
  }

  /// 取 pending 队首任务并在空 slot 上启动。lock 内只做"取"（取 pending 首 + 占空 slot），**解锁
  /// 后锁外调 startJob**（C3）。无 pending 或无空 slot 则什么都不做。
  private func dispatchNextPending() {
    var nextJob: Job? = nil
    var assignedSlot: PoolSlot? = nil
    lock.lock()
    if !pending.isEmpty, let slot = slots.first(where: { $0.job == nil }) {
      nextJob = pending.removeFirst()
      slot.job = nextJob
      assignedSlot = slot
    }
    lock.unlock()
    // 恒锁外启动，防 NSLock 重入死锁（B4 / C3）。
    if let job = nextJob, let slot = assignedSlot {
      startJob(on: slot, job: job)
    }
  }

  /// 在已占位的 slot 上启动 FFmpegController 生成。`job` 由调用方在外部构造并已 `slot.job = job`。
  /// 仅设置超时与触发 FFmpeg 生成（锁内只读 `slot.job` 做超时判定）。
  private func startJob(on slot: PoolSlot, job: Job) {
    let url = job.url
    // Timeout: degrade to nil if the delegate does not fire in time.
    queue.asyncAfter(deadline: .now() + MediaThumbnailer.timeout) { [weak self, weak slot] in
      guard let self = self, let slot = slot else { return }
      var cb: ((NSImage?) -> Void)? = nil
      var didTimeout = false
      self.lock.lock()
      let active = slot.job != nil && !slot.job!.timedOut
      if active, slot.job?.url.path == url.path {
        slot.job?.timedOut = true
        cb = slot.job?.completion
        slot.job = nil
        didTimeout = true
      }
      self.lock.unlock()
      if let cb = cb {
        // 计数：超时降级视为完成（completion 以 nil 回调，C7 不变量 completed ≤ total）。
        if didTimeout {
          self.lock.lock()
          self.completedCount += 1
          self.lock.unlock()
        }
        DispatchQueue.main.async { cb(nil) }
        // slot 已释放，驱动 pending 队列（必须在 unlock 之后）——C3。
        self.dispatchNextPending()
      }
    }

    slot.controller.generateThumbnail(forFile: url.path, thumbWidth: Int32(MediaThumbnailer.thumbWidth))
  }

  // MARK: Cache helpers

  static func cacheName(for url: URL, ignorePath: Bool) -> String {
    return Utility.mpvWatchLaterMd5(url, ignorePath)
  }

  static func cacheDirectoryURL() -> URL {
    // Test-isolation seam: under `-iinaTestDataRoot` (XCUI tests) redirect thumbnail writes to the
    // test data root so the production `~/Library/Caches/.../media_thumbnails` is never polluted.
    if let root = Utility.testDataRootURL {
      return root.appendingPathComponent(cacheSubdir, isDirectory: true)
    }
    return Utility.thumbnailCacheURL.appendingPathComponent(cacheSubdir, isDirectory: true)
  }
}

// MARK: - Thumbnail completion (called by PoolSlot delegate)

extension MediaThumbnailer {

  /// Called by the owning `PoolSlot` when its `FFmpegController` finishes. The slot is passed
  /// directly so we resolve the exact job without filename matching (fixes B2).
  private func handleDidGenerate(slot: PoolSlot, thumbnails: [FFThumbnail], succeeded: Bool) {
    Logger.log("MediaThumbnailer.handleDidGenerate succeeded=\(succeeded) count=\(thumbnails.count)", level: .warning)
    lock.lock()
    guard let job = slot.job, !job.timedOut else {
      lock.unlock()
      return
    }
    slot.job = nil
    // 计数：FFmpeg 回调到达（成功或失败）即视为完成（C7，completion 必然触发）。在 slot.job=nil
    // 之后、unlock 之前完成 completed++（仍持锁），保持不变量原子可见。
    completedCount += 1
    lock.unlock()

    let picked: NSImage? = {
      guard succeeded, !thumbnails.isEmpty else { return nil }
      return MediaThumbnailer.pickBrightestFrame(thumbnails)
    }()

    if let img = picked {
      if let tiff = img.tiffRepresentation,
         let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: job.cacheURL, options: .atomic)
      }
    }
    DispatchQueue.main.async { job.completion(picked) }
    // slot 已释放，驱动 pending 队列（必须在 unlock 之后）——C3。
    dispatchNextPending()
  }

  // MARK: Smart frame selection

  /// Pick the frame with the highest average luminance among the candidates. If every frame is
  /// near-black (below `blackLuminanceThreshold`), fall back to `fallbackFrameIndex` (clamped to
  /// the available range) so the card isn't pure black.
  ///
  /// Luminance is computed as the mean gray value (Rec. 601: 0.299R + 0.587G + 0.114B) across
  /// the frame's pixels, sampled via the NSBitmapImageRep. Sampling is done off the main thread
  /// (this method is called from the FFmpeg delegate callback queue).
  static func pickBrightestFrame(_ thumbnails: [FFThumbnail]) -> NSImage? {
    guard !thumbnails.isEmpty else { return nil }

    var bestIdx = -1
    var bestLuma: Double = -1
    for (i, thumb) in thumbnails.enumerated() {
      let luma = averageLuminance(of: thumb.image)
      if luma > bestLuma {
        bestLuma = luma
        bestIdx = i
      }
    }

    // All-black fallback: if the brightest frame is still near-black, use the fallback index so
    // we don't pin the card to a single black frame when a slightly less-black frame at ~20%
    // might at least show a logo. Clamp index to bounds defensively.
    if bestLuma < MediaThumbnailer.blackLuminanceThreshold {
      let fallback = min(max(MediaThumbnailer.fallbackFrameIndex, 0), thumbnails.count - 1)
      Logger.log("MediaThumbnailer: all frames near-black (best=\(bestLuma)), fallback idx=\(fallback)", level: .warning)
      return thumbnails[fallback].image
    }

    Logger.log("MediaThumbnailer: picked idx=\(bestIdx) luma=\(bestLuma) of \(thumbnails.count) frames", level: .warning)
    return thumbnails[bestIdx].image
  }

  /// Compute the average luminance (0–255) of an image. Returns -1 on failure.
  private static func averageLuminance(of image: NSImage?) -> Double {
    guard let image = image,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
      return -1
    }
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    guard width > 0, height > 0 else { return -1 }

    // Sample on a stride to keep this cheap (large images don't need per-pixel analysis to
    // compare relative brightness). Target ~4096 samples.
    let targetSamples = 2048
    let totalPixels = width * height
    let step = max(1, Int((Double(totalPixels) / Double(targetSamples)).rounded(.up)))

    var sum: Double = 0
    var count: Double = 0
    for y in Swift.stride(from: 0, to: height, by: step) {
      for x in Swift.stride(from: 0, to: width, by: step) {
        if let nsColor = rep.colorAt(x: x, y: y) {
          // sRGB → luma (Rec. 601), scaled to 0–255.
          let r = nsColor.redComponent
          let g = nsColor.greenComponent
          let b = nsColor.blueComponent
          let luma = (0.299 * r + 0.587 * g + 0.114 * b) * 255.0
          sum += luma
          count += 1
        }
      }
    }
    guard count > 0 else { return -1 }
    return sum / count
  }
}
