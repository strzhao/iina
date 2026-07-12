//
//  MediaLibraryStore.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

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

  /// True while a rescan is in progress (UI shows "扫描中…" instead of the empty state).
  private(set) var isScanning: Bool = false

  private override init() {
    super.init()
    loadIndex()
  }

  // MARK: Root path

  /// The configured media library root path. Falls back to the default NAS mount if unset.
  var rootPath: String {
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
  /// main thread when complete (or on error, with an empty items list + the error in userInfo).
  func rescan() {
    Logger.log("MediaLibraryStore.rescan start root=\(rootPath)", level: .warning)
    isScanning = true
    scanQueue.async { [weak self] in
      guard let self = self else { return }
      let scanner = MediaLibraryScanner()
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
          self.items = []
          self.md5Index = [:]
          self.tvShowIndex = [:]
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

  /// Items with playback progress < 95% of duration, not marked played, sorted by last-played,
  /// limited to 10. Joins to `HistoryController` via `mpvMd5`.
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
      // Exclude marked played.
      if entry.played { continue }
      // Duration guard.
      let durationSec: Double
      if let d = item.duration { durationSec = d }
      else if entry.duration.second > 0 { durationSec = entry.duration.second }
      else { continue }
      // Progress guard: must have a progress and be < 95% of duration.
      guard let progressSec = entry.mpvProgress?.second, progressSec > 0 else { continue }
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

  /// Playback progress (seconds) for a media item, if recorded in history. 0/nil if none.
  func progress(for item: MediaItem) -> Double? {
    let ignorePath = currentIgnorePath()
    let md5 = Utility.mpvWatchLaterMd5(item.url, ignorePath)
    let entry = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    return entry?.mpvProgress?.second
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

  // MARK: Helpers

  /// Current `ignorePathInWatchLaterConfig`, read from the active PlayerCore. Falls back to false
  /// if no player is available (matching mpv's default).
  private func currentIgnorePath() -> Bool {
    return PlayerCore.activeOrNew.ignorePathInWatchLaterConfig
  }
}
