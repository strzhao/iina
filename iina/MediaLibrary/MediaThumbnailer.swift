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
/// We take **index 1** (~20% position) to avoid black screens at intro/outro.
///
/// Caching reuses `ThumbnailCache`'s directory under `Utility.thumbnailCacheURL` in a
/// `media_thumbnails/` subdirectory. The cache key is
/// `Utility.mpvWatchLaterMd5(url, ignorePath)`.
final class MediaThumbnailer: NSObject {

  /// Shared singleton used by the media library UI.
  static let shared = MediaThumbnailer()

  /// Number of `FFmpegController` instances in the pool. Bounds concurrent generation to ≤3.
  private static let poolSize = 3

  /// Thumbnails to generate per file. FFmpegController emits `thumbnailCount + 1` frames.
  private static let thumbnailCount: Int = 5

  /// Index of the frame to pick (≈20% position; avoids black intro/outro).
  private static let pickedFrameIndex: Int = 1

  /// Per-file generation timeout (seconds). On expiry, completion is called with nil.
  private static let timeout: TimeInterval = 10

  /// Thumbnail width in pixels.
  private static let thumbWidth: Int = 320

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
    let cacheName = MediaThumbnailer.cacheName(for: url, ignorePath: ignorePath)
    let cacheURL = MediaThumbnailer.cacheDirectoryURL().appendingPathComponent(cacheName + ".png")
    Logger.log("  cacheDir=\(MediaThumbnailer.cacheDirectoryURL().path) dirExists=\(FileManager.default.fileExists(atPath: MediaThumbnailer.cacheDirectoryURL().path))", level: .warning)

    // Cache hit: load existing PNG.
    if let img = NSImage(contentsOf: cacheURL) {
      DispatchQueue.main.async { completion(img) }
      return
    }

    queue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      self.dispatch(url: url, ignorePath: ignorePath, cacheName: cacheName, cacheURL: cacheURL, completion: completion, attempt: 0)
    }
  }

  /// Clear all cached media-library thumbnails.
  static func clearCache() {
    let dir = cacheDirectoryURL()
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  // MARK: Internals

  private func dispatch(url: URL, ignorePath: Bool, cacheName: String, cacheURL: URL, completion: @escaping (NSImage?) -> Void, attempt: Int) {
    let slot = lock.withLock { slots.first(where: { $0.job == nil }) }
    if let slot = slot {
      startJob(on: slot, url: url, ignorePath: ignorePath, cacheName: cacheName, cacheURL: cacheURL, completion: completion)
    } else if attempt < 4 {
      // All slots busy — retry after a short backoff.
      queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.dispatch(url: url, ignorePath: ignorePath, cacheName: cacheName, cacheURL: cacheURL, completion: completion, attempt: attempt + 1)
      }
    } else {
      DispatchQueue.main.async { completion(nil) }
    }
  }

  private func startJob(on slot: PoolSlot, url: URL, ignorePath: Bool, cacheName: String, cacheURL: URL, completion: @escaping (NSImage?) -> Void) {
    let job = Job(url: url, ignorePath: ignorePath, cacheName: cacheName, cacheURL: cacheURL, completion: completion)
    lock.lock()
    slot.job = job
    lock.unlock()

    // Timeout: degrade to nil if the delegate does not fire in time.
    queue.asyncAfter(deadline: .now() + MediaThumbnailer.timeout) { [weak self, weak slot] in
      guard let self = self, let slot = slot else { return }
      self.lock.lock()
      let active = slot.job != nil && !slot.job!.timedOut
      if active, slot.job?.url.path == url.path {
        slot.job?.timedOut = true
        let cb = slot.job?.completion
        slot.job = nil
        self.lock.unlock()
        if let cb = cb { DispatchQueue.main.async { cb(nil) } }
      } else {
        self.lock.unlock()
      }
    }

    slot.controller.generateThumbnail(forFile: url.path, thumbWidth: Int32(MediaThumbnailer.thumbWidth))
  }

  // MARK: Cache helpers

  static func cacheName(for url: URL, ignorePath: Bool) -> String {
    return Utility.mpvWatchLaterMd5(url, ignorePath)
  }

  static func cacheDirectoryURL() -> URL {
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
    lock.unlock()

    let picked: NSImage? = {
      guard succeeded, thumbnails.count > MediaThumbnailer.pickedFrameIndex else { return nil }
      return thumbnails[MediaThumbnailer.pickedFrameIndex].image
    }()

    if let img = picked {
      if let tiff = img.tiffRepresentation,
         let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: job.cacheURL, options: .atomic)
      }
    }
    DispatchQueue.main.async { job.completion(picked) }
  }
}
