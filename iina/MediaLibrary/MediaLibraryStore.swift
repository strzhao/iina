//
//  MediaLibraryStore.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

/// A TV-show collection card: one representative `MediaItem` plus the total episode count.
/// Used by the grid so that each show occupies a single card instead of one card per episode.
struct TVShowGroup {
  let representative: MediaItem
  let episodeCount: Int
}

/// Singleton holding the scanned media library items, the persisted index, and query helpers
/// (filtering, continue-watching, TV-show episodes).
///
/// Progress association uses `Utility.mpvWatchLaterMd5(url, ignorePath)` to match a `MediaItem`
/// against `HistoryController.shared.history` entries (keyed by `mpvMd5`). The `ignorePath` value
/// is taken from `PlayerCore.activeOrNew.ignorePathInWatchLaterConfig` so it matches what
/// `HistoryController.add` records — otherwise the join would silently fail.
final class MediaLibraryStore: NSObject {

  static let shared = MediaLibraryStore()

  /// Notification posted when a scan completes and the store's items have been refreshed.
  static let scannedNotification = Notification.Name("iinaMediaLibraryScanned")

  /// 扫描进度通知（P1-5）。`userInfo["discovered"] = Int`（累计已发现项数）。由 `rescan()`
  /// 注入 Scanner 的 progressHandler 桥接而来，回调一律经 `DispatchQueue.main.async` post
  /// （C6）。VC 监听此通知更新进度 label + spinner，**不触发 reloadData/reconfigureVisibleItems**
  /// （C2）。userInfo key = "discovered"。
  static let iinaMediaScanProgress = Notification.Name("iinaMediaScanProgress")

  /// Maximum number of items returned by `continueWatchingItems()`.
  private static let continueWatchingLimit = 10

  /// An item counts as "watched" (and is excluded from continue-watching) at ≥95% of duration.
  private static let watchedThreshold = 0.95

  // MARK: State

  /// All scanned items. Access on main thread; mutations post `scannedNotification`.
  private(set) var items: [MediaItem] = []

  /// Cached lookup: mpvMd5 → MediaItem, rebuilt on each scan.
  private var md5Index: [String: MediaItem] = [:]

  /// Cached lookup: tvShowId → episodes (sorted by episodeNumber).
  private var tvShowIndex: [String: [MediaItem]] = [:]

  /// Path to the persisted index plist.
  private let indexURL: URL = {
    Utility.appSupportDirUrl.appendingPathComponent("media_library_index.plist", isDirectory: false)
  }()

  /// Background queue for scanning.
  private let scanQueue = DispatchQueue(label: "iina.media.library.scan", qos: .userInitiated)

  /// 并发限宽（4）的 OperationQueue，用于惰性元数据探测。原来用 serial DispatchQueue 时，单个
  /// NAS 慢文件的 `avformat_open_input` 会卡死整条队列、所有卡片元数据长期空白；改并发后单慢文件
  /// 不再阻塞其他 item 的探测完成（P0-3）。`probingKeys`/`probedKeys` 已防重探 stampede，
  /// 因此并发数可控。`userInitiated` 保持卡片响应。
  private let probeQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "iina.media.library.probe"
    q.qualityOfService = .userInitiated
    q.maxConcurrentOperationCount = 4
    return q
  }()

  /// Notification posted when a single item's metadata has been lazily probed and updated. The
  /// object is the `MediaItem`. Observers (e.g. the grid) refresh the corresponding card.
  static let metadataProbedNotification = Notification.Name("iinaMediaLibraryMetadataProbed")

  /// Set of mpvMd5 keys currently in-flight on `probeQueue`, to avoid re-probing the same item
  /// while a probe is pending. Guarded by `probeLock`.
  internal var probingKeys: Set<String> = []  // @testable seam（红队 ACC-preserve 防循环）；写仍由 probeLock 守卫
  private let probeLock = NSLock()

  /// True while a rescan is in progress (UI shows "扫描中…" instead of the empty state).
  private(set) var isScanning: Bool = false

  private override init() {
    super.init()
    loadIndex()
  }

  // MARK: Root path

  /// The configured media library root path. Falls back to the default NAS mount if unset.
  var rootPath: String {
    // 测试 seam：XCUIApplication launchArguments `-mediaLibraryRootPath <path>` 注入测试媒体路径。
    // 仅 UI 测试用（生产正常启动无此参数，走 UserDefaults 分支）。
    if let idx = CommandLine.arguments.firstIndex(of: "-mediaLibraryRootPath"),
       idx + 1 < CommandLine.arguments.count {
      return CommandLine.arguments[idx + 1]
    }
    let stored = UserDefaults.standard.string(forKey: "mediaLibraryRootPath")
    if let stored = stored, !stored.isEmpty {
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: stored, isDirectory: &isDir), isDir.boolValue {
        return stored
      }
    }
    return "/Volumes/stringzhao_主空间/迅雷下载"
  }

  var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }

  // MARK: Scan

  /// Trigger an asynchronous rescan of the root directory. Posts `scannedNotification` on the
  /// main thread when complete, or on error with the error in `userInfo`. On error the previously
  /// cached items (from `loadIndex`) are preserved so a transient NAS I/O hiccup doesn't wipe the
  /// whole library view.
  func rescan() {
    Logger.log("MediaLibraryStore.rescan start root=\(rootPath)", level: .warning)
    isScanning = true
    scanQueue.async { [weak self] in
      guard let self = self else { return }
      let scanner = MediaLibraryScanner()
      // P1-5 / B2：注入进度回调，桥接到 `.iinaMediaScanProgress` 通知。Scanner 在本 scanQueue
      // 单线程回调（C6），此处仅做 main post（零数据层改动，不改 setItems/rebuildIndices/probe/
      // FIFO）。节流与 finalCount flush 由 Scanner 内部保证。
      scanner.progressHandler = { count in
        DispatchQueue.main.async {
          NotificationCenter.default.post(
            name: MediaLibraryStore.iinaMediaScanProgress,
            object: self,
            userInfo: ["discovered": count])
        }
      }
      do {
        let result = try scanner.scan(root: self.rootURL)
        Logger.log("MediaLibraryStore.rescan done items=\(result.count)", level: .warning)
        DispatchQueue.main.async {
          self.isScanning = false
          self.setItems(result)
          self.saveIndex()
          NotificationCenter.default.post(name: MediaLibraryStore.scannedNotification, object: self)
        }
      } catch {
        Logger.log("MediaLibraryStore.rescan error: \(error)", level: .error)
        DispatchQueue.main.async {
          self.isScanning = false
          // Keep cached items on transient scan failures — a flaky NAS I/O hiccup shouldn't wipe
          // the whole library view. The error is still surfaced via the notification so the user
          // knows the rescan didn't refresh.
          NotificationCenter.default.post(
            name: MediaLibraryStore.scannedNotification, object: self,
            userInfo: ["error": error])
        }
      }
    }
  }

  /// Replace the in-memory items and rebuild indices. Main-thread only.
  func setItems(_ newItems: [MediaItem]) {
    items = newItems
    rebuildIndices()
  }

  /// Test-only fixture: reset the store's items and rebuild indices. Equivalent to `setItems`,
  /// named for test-fixture clarity so acceptance tests read intent. Main-thread only.
  func setItemsForTesting(_ newItems: [MediaItem]) {
    setItems(newItems)
  }

  private func rebuildIndices() {
    var md5: [String: MediaItem] = [:]
    var tv: [String: [MediaItem]] = [:]
    let ignorePath = currentIgnorePath()
    for item in items {
      let key = Utility.mpvWatchLaterMd5(item.url, ignorePath)
      md5[key] = item
      if let showId = item.tvShowId {
        tv[showId, default: []].append(item)
      }
    }
    md5Index = md5
    for (k, var v) in tv {
      v.sort { (a, b) -> Bool in
        if let ae = a.episodeNumber, let be = b.episodeNumber { return ae < be }
        return a.url.lastPathComponent < b.url.lastPathComponent
      }
      tv[k] = v
    }
    tvShowIndex = tv
  }

  // MARK: Queries

  /// Filter items by category and/or a search string (matched against cleanedName, case-insensitive).
  func items(category: MediaCategory?, filter: String?) -> [MediaItem] {
    var result = items
    if let category = category {
      result = result.filter { $0.category == category }
    }
    if let filter = filter, !filter.isEmpty {
      let needle = filter.lowercased()
      result = result.filter { $0.cleanedName.lowercased().contains(needle) }
    }
    return result
  }

  /// Items with playback progress < 95% of duration, sorted by last-played, limited to 10.
  /// Joins to `HistoryController` via `mpvMd5`.
  ///
  /// `played` is intentionally not consulted: `HistoryController.add` hardcodes `played=true` on
  /// every entry, so filtering on it would exclude the entire history.
  func continueWatchingItems() -> [MediaItem] {
    let ignorePath = currentIgnorePath()
    let history = HistoryController.shared.history
    var pairs: [(item: MediaItem, addedDate: Date)] = []
    for entry in history {
      // Match by URL first (most reliable), then by md5.
      var matched: MediaItem? = md5Index[entry.mpvMd5]
      if matched == nil {
        matched = items.first { Utility.mpvWatchLaterMd5($0.url, ignorePath) == entry.mpvMd5 }
      }
      guard let item = matched else { continue }
      // Duration guard.
      let durationSec: Double
      if let d = item.duration { durationSec = d }
      else if entry.duration.second > 0 { durationSec = entry.duration.second }
      else { continue }
      // Progress guard: read watch-later LIVE (not entry.mpvProgress, which is a startup snapshot
      // set once in PlaybackHistory.init(coder:) and never refreshed — newly played entries have
      // mpvProgress==nil and wouldn't appear until restart). This makes continue-watching reflect
      // the latest playback without restarting.
      guard let progressSec = Utility.playbackProgressFromWatchLater(entry.mpvMd5)?.second,
            progressSec > 0 else { continue }
      if progressSec >= durationSec * MediaLibraryStore.watchedThreshold { continue }
      pairs.append((item: item, addedDate: entry.addedDate))
    }
    pairs.sort { $0.addedDate > $1.addedDate }
    return Array(pairs.prefix(MediaLibraryStore.continueWatchingLimit)).map { $0.item }
  }

  /// All episodes of a TV show, sorted by episode number.
  func tvShowEpisodes(tvShowId: String) -> [MediaItem] {
    return tvShowIndex[tvShowId] ?? []
  }

  /// The last-watched episode of a TV show (by history addedDate), or nil if none.
  func lastWatchedEpisode(tvShowId: String) -> MediaItem? {
    let episodes = tvShowEpisodes(tvShowId: tvShowId)
    guard !episodes.isEmpty else { return nil }
    let ignorePath = currentIgnorePath()
    let history = HistoryController.shared.history
    var best: (MediaItem, Date)? = nil
    for entry in history {
      guard let ep = episodes.first(where: { Utility.mpvWatchLaterMd5($0.url, ignorePath) == entry.mpvMd5 }) else { continue }
      if best == nil || entry.addedDate > best!.1 {
        best = (ep, entry.addedDate)
      }
    }
    return best?.0
  }

  /// Group every TV show in `tvShowIndex` into one `TVShowGroup` per `tvShowId`.
  ///
  /// Representative selection: `lastWatchedEpisode(tvShowId:)` if any, else the first episode
  /// (episodes are already sorted by `episodeNumber` in `rebuildIndices`). `episodeCount` is the
  /// total number of episodes for that show (≥ 1).
  ///
  /// `filter`: nil or empty → all groups; otherwise case-insensitive `contains` against the
  /// representative's `cleanedName`. Result sorted by `representative.cleanedName` ascending
  /// (deterministic). Main-thread only; does not mutate `tvShowIndex` / `items`.
  func tvShowGroups(filter: String?) -> [TVShowGroup] {
    var groups: [TVShowGroup] = []
    groups.reserveCapacity(tvShowIndex.count)
    for (showId, episodes) in tvShowIndex {
      guard !episodes.isEmpty else { continue }
      let representative = lastWatchedEpisode(tvShowId: showId) ?? episodes[0]
      // Defensive: the representative must carry the same tvShowId as the key.
      guard representative.tvShowId == showId else { continue }
      groups.append(TVShowGroup(representative: representative, episodeCount: episodes.count))
    }
    if let filter = filter, !filter.isEmpty {
      let needle = filter.lowercased()
      groups = groups.filter { $0.representative.cleanedName.lowercased().contains(needle) }
    }
    groups.sort { $0.representative.cleanedName < $1.representative.cleanedName }
    return groups
  }

  /// Playback progress (seconds) for a media item, read LIVE from watch-later. Returns nil if no
  /// watch-later file / no `start=`. Reading live (rather than `entry.mpvProgress`, a startup
  /// snapshot) keeps card progress bars current after new playback without restarting.
  func progress(for item: MediaItem) -> Double? {
    let ignorePath = currentIgnorePath()
    let md5 = Utility.mpvWatchLaterMd5(item.url, ignorePath)
    return Utility.playbackProgressFromWatchLater(md5)?.second
  }

  // MARK: Persistence

  /// Load the cached index from disk (best-effort; corrupt/missing → empty).
  func loadIndex() {
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
    do {
      let data = try Data(contentsOf: indexURL)
      let object = try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSArray.self, MediaItem.self], from: data)
      if let arr = object as? [MediaItem] {
        self.items = arr
        rebuildIndices()
      }
    } catch {
      // Corrupt index — start fresh.
      self.items = []
      rebuildIndices()
    }
  }

  /// Persist the current items to the index plist (main-thread call).
  func saveIndex() {
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: true)
      try data.write(to: indexURL, options: [.atomic])
    } catch {
      // Non-fatal: index is only a cache.
    }
  }

  // MARK: Lazy metadata probing (P3)

  /// Lazily probe width/height/videoCodec/bitrate/duration for an item via libavformat, and fill
  /// the year from `FileNameCleaner`. Runs on a serial background queue; on success the item's
  /// fields are updated, `saveIndex()` persists, and `metadataProbedNotification` is posted so the
  /// grid can refresh that card. No-op if the item already has a probed `height` (heuristic that
  /// the probe completed once). Failures degrade silently: fields stay nil, no crash (P3.3).
  ///
  /// Designed to be called when a card becomes visible. It does not block first paint — the card
  /// reads already-cached fields immediately and is refreshed when the probe completes.
  /// Keys for items whose metadata probe has completed (success or failure). Prevents re-probing
  /// items whose probe yielded no height (NAS I/O hiccup / no video stream) — without this, every
  /// configure would re-probe and re-post metadataProbedNotification → reload → flicker loop.
  internal var probedKeys: Set<String> = []  // @testable seam（红队 ACC-preserve 防循环）；写仍由 probeLock 守卫

  func probeMetadata(for item: MediaItem) {
    // Already probed (height present, or previously attempted): nothing to do.
    if item.height != nil { return }
    let ignorePath = currentIgnorePath()
    let key = Utility.mpvWatchLaterMd5(item.url, ignorePath)
    probeLock.lock()
    if probingKeys.contains(key) || probedKeys.contains(key) {
      probeLock.unlock()
      return
    }
    probingKeys.insert(key)
    probeLock.unlock()

    // 后台块只做两件事：慢 IO（probeVideoInfo）+ probeLock 内簿记（移除 probingKeys / 标记
    // probedKeys）。**完全不碰任何 MediaItem var 字段**（width/height/year/videoCodec/
    // bitrate/duration 全部留给主线程的 applyProbeResult 读写）——避免与主线程的 configure /
    // saveIndex 竞态（P0-1 / C1 / C1b）。仅 `item.url.path`（let，init 后不可变）在后台读。
    probeQueue.addOperation { [weak self] in
      guard let self = self else { return }
      let info = FFmpegController.probeVideoInfo(forFile: item.url.path)
      self.probeLock.lock()
      self.probingKeys.remove(key)
      self.probedKeys.insert(key)
      self.probeLock.unlock()
      // 跳主线程应用：item 所有 var 字段只在主线程被写（C1）。
      DispatchQueue.main.async {
        self.applyProbeResult(item: item, info: info)
      }
    }
  }

  /// 主线程应用探测结果（P0-1）。**仅主线程**被调用：写入 item 的 year/width/height/
  /// videoCodec/bitrate/duration，必要时持久化并发通知。**不持 probeLock**（saveIndex 较重，
  /// 不应在锁内执行；簿记已在后台块完成）。
  private func applyProbeResult(item: MediaItem, info: Any?) {
    // 始终先用文件名补 year（廉价、总有）。
    if item.year == nil {
      let cleaned = FileNameCleaner.clean(item.rawName)
      item.year = cleaned.year
    }
    var changed = item.year != nil
    // 通过 libavformat 探测；info 为 nil 则静默降级（字段保持 nil，不崩溃）。
    if let info = info as? [String: Any] {
      if let w = info["@iina_width"] as? Int { item.width = w; changed = true }
      if let w = info["@iina_width"] as? NSNumber { item.width = w.intValue; changed = true }
      if let h = info["@iina_height"] as? Int { item.height = h; changed = true }
      if let h = info["@iina_height"] as? NSNumber { item.height = h.intValue; changed = true }
      if let codec = info["@iina_video_codec"] as? String { item.videoCodec = codec; changed = true }
      if let br = info["@iina_bit_rate"] as? Int { item.bitrate = br; changed = true }
      if let br = info["@iina_bit_rate"] as? NSNumber { item.bitrate = br.intValue; changed = true }
      if let dur = info["@iina_duration"] as? Double, dur > 0 {
        item.duration = dur; changed = true
      }
      if let dur = info["@iina_duration"] as? NSNumber, dur.doubleValue > 0 {
        item.duration = dur.doubleValue; changed = true
      }
    }

    guard changed else { return }
    saveIndex()
    NotificationCenter.default.post(name: MediaLibraryStore.metadataProbedNotification, object: item)
  }

  // MARK: Helpers

  /// Current `ignorePathInWatchLaterConfig`, read from the active PlayerCore. Falls back to false
  /// if no player is available (matching mpv's default).
  private func currentIgnorePath() -> Bool {
    return PlayerCore.activeOrNew.ignorePathInWatchLaterConfig
  }

  // MARK: @testable 契约 seam（红队验收测试用；不影响生产行为）

  /// probe 并发限宽（C4 / P0-3）。红队 ACC-P0-3 断言 == 4。
  internal var probeQueueMaxConcurrent: Int { return probeQueue.maxConcurrentOperationCount }

  /// item 的 probe key（mpvMd5）。红队 ACC-preserve 用以比对 probedKeys/probingKeys。
  internal func probeKey(for item: MediaItem) -> String {
    return Utility.mpvWatchLaterMd5(item.url, currentIgnorePath())
  }
}
