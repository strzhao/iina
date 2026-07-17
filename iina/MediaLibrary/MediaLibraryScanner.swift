//
//  MediaLibraryScanner.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

/// Recursively scans the media library root directory and produces `[MediaItem]`.
///
/// The root must contain three fixed subdirectories: `电影` (movies), `电视剧` (TV shows),
/// `其它` (other). For TV shows, each immediate subdirectory is one show; files within are
/// episodes. Video files are filtered by extension whitelist
/// `{mkv, mp4, avi, mov, m4v, ts, flv, webm}` (excludes e.g. `.png` promo images mixed into
/// TV show dirs).
///
/// Scanning is synchronous but lightweight (file enumeration + name cleaning only); thumbnail
/// generation is deferred to `MediaThumbnailer` and happens on-demand when a card becomes visible.
/// Duration is probed lazily and cached on the returned `MediaItem`.
final class MediaLibraryScanner {

  /// Video file extensions recognized by the media library (lowercase, no dot).
  static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v", "ts", "flv", "webm"]

  /// Fixed subdirectories under the root, mapped to their categories.
  static let fixedSubdirs: [(name: String, category: MediaCategory)] = [
    ("电影", .movie),
    ("电视剧", .tvShow),
    ("其它", .other),
  ]

  private let fileManager: FileManager

  /// 扫描进度回调（参数 = 累计已发现项数）。仅在 `scan(root:)` 所在的单线程（Store 的
  /// `scanQueue`）上回调——Scanner 内部不改并发遍历，故节流时间戳无需加锁（C6）。节流
  /// ≥100ms，且 `scan(root:)` return 前强制 flush 一次 finalCount（防丢最终态，ISSUE-1）。
  /// Store 注入此闭包以桥接 `.iinaMediaScanProgress` 通知；Scanner 本身保持纯逻辑（不直接
  /// 用 NotificationCenter），单测可喂固定目录断言回调计数。
  var progressHandler: ((Int) -> Void)?

  /// 节流时间戳（`progressHandler` 上次回调时刻）。仅在 scan 所在单线程读写，无需加锁。
  private var lastProgressCallbackAt: Date = .distantPast
  /// 节流间隔（秒）。≥100ms 回调一次，避免大库每文件回调导致 main post 风暴。
  private static let throttleInterval: TimeInterval = 0.1

  /// 本轮 scan 累计已发现项数（`scan(root:)` 入口 reset）。仅在 scan 所在单线程读写，无需
  /// 加锁（C6）。每个 append 点 mutate 后调 `reportProgress(discovered:)` 节流回调。
  private var discoveredCount: Int = 0

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  /// 节流回调 progressHandler（C6）。仅在 scan 所在单线程调用。距上次回调 ≥ throttleInterval
  /// 才真正回调；否则跳过（下次 append 或 return 前 flush 会补）。
  private func reportProgress(discovered count: Int, force: Bool = false) {
    guard let handler = progressHandler else { return }
    let now = Date()
    if force || now.timeIntervalSince(lastProgressCallbackAt) >= MediaLibraryScanner.throttleInterval {
      lastProgressCallbackAt = now
      handler(count)
    }
  }

  /// Scan the root directory and return all discovered media items.
  ///
  /// - Parameter root: Root URL containing the three fixed subdirectories.
  /// - Returns: Array of `MediaItem`. Empty if subdirectories exist but contain no videos.
  /// - Throws: `MediaLibraryError.pathNotAccessible` if the root is not readable;
  ///   `MediaLibraryError.scanFailed` on I/O errors.
  func scan(root: URL) throws -> [MediaItem] {
    // 进度计数 / 节流时间戳重置（每次 scan 独立；Scanner 实例虽通常一次性，但 reset 保险）。
    discoveredCount = 0
    lastProgressCallbackAt = .distantPast

    // Root must exist and be readable (directory).
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
      throw MediaLibraryError.pathNotAccessible(url: root)
    }
    guard fileManager.isReadableFile(atPath: root.path) else {
      throw MediaLibraryError.pathNotAccessible(url: root)
    }

    var items: [MediaItem] = []
    for (subdirName, category) in MediaLibraryScanner.fixedSubdirs {
      let subdirURL = root.appendingPathComponent(subdirName, isDirectory: true)
      // Missing subdirectory is not fatal — skip (empty category).
      var subdirIsDir: ObjCBool = false
      guard fileManager.fileExists(atPath: subdirURL.path, isDirectory: &subdirIsDir), subdirIsDir.boolValue else {
        continue
      }
      do {
        let subItems = try scanCategory(subdirURL, category: category)
        items.append(contentsOf: subItems)
      } catch let error as MediaLibraryError {
        throw error
      } catch {
        throw MediaLibraryError.scanFailed(url: subdirURL, underlying: error)
      }
    }
    // C6 / ISSUE-1：return 前强制 flush 最终计数，防丢最终态（节流可能跳过最后一批 append）。
    reportProgress(discovered: items.count, force: true)
    return items
  }

  // MARK: Per-category scanning

  private func scanCategory(_ dir: URL, category: MediaCategory) throws -> [MediaItem] {
    var items: [MediaItem] = []
    let contents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    // Sort for deterministic ordering.
    let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }

    switch category {
    case .movie, .other:
      // Each entry is either a video file directly under the category dir, or a subdirectory
      // containing a video file (download-site packaging: dir name = title + prefix, video
      // inside). For subdirs, use the cleaned dir name as the display name and pick the first
      // video file inside as the playable URL. Fixes C1: previously only direct video files
      // were scanned, missing ~81% of movies that live one level down in a subdir.
      for entryURL in sorted {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: entryURL.path, isDirectory: &isDir), isDir.boolValue {
          let cleaned = FileNameCleaner.cleanShowName(entryURL.lastPathComponent)
          if let video = (try? fileManager.contentsOfDirectory(at: entryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter({ isVideoFile($0) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            items.append(MediaItem(
              url: video,
              cleanedName: cleaned,
              rawName: entryURL.lastPathComponent,
              category: category,
              tvShowId: nil
            ))
            discoveredCount += 1
            reportProgress(discovered: discoveredCount)
          }
        } else if isVideoFile(entryURL) {
          items.append(makeItem(url: entryURL, category: category, tvShowId: nil))
          discoveredCount += 1
          reportProgress(discovered: discoveredCount)
        }
      }
    case .tvShow:
      // Each subdirectory is one show; files within are episodes.
      for subURL in sorted {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: subURL.path, isDirectory: &isDir), isDir.boolValue {
          let showId = FileNameCleaner.cleanShowName(subURL.lastPathComponent)
          let episodes = try scanEpisodes(in: subURL, tvShowId: showId)
          items.append(contentsOf: episodes)
          // scanEpisodes 内部已逐集累计 discoveredCount + 节流回调；此处再补一次本 show 的累计汇报。
          reportProgress(discovered: discoveredCount)
        } else if isVideoFile(subURL) {
          // A stray video file directly under 电视剧 (not in a show dir): treat as a standalone.
          items.append(makeItem(url: subURL, category: .tvShow, tvShowId: nil))
          discoveredCount += 1
          reportProgress(discovered: discoveredCount)
        }
      }
    }
    return items
  }

  /// Scan episodes within a TV show directory.
  private func scanEpisodes(in showDir: URL, tvShowId: String) throws -> [MediaItem] {
    var items: [MediaItem] = []
    let contents = try fileManager.contentsOfDirectory(at: showDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    for fileURL in sorted {
      if isVideoFile(fileURL) {
        items.append(makeItem(url: fileURL, category: .tvShow, tvShowId: tvShowId))
        discoveredCount += 1
        reportProgress(discovered: discoveredCount)
      }
    }
    return items
  }

  // MARK: Helpers

  private func isVideoFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return MediaLibraryScanner.videoExtensions.contains(ext)
  }

  private func makeItem(url: URL, category: MediaCategory, tvShowId: String?) -> MediaItem {
    let rawName = url.lastPathComponent
    let cleaned = FileNameCleaner.clean(rawName)
    return MediaItem(
      url: url,
      cleanedName: cleaned.cleanedName,
      rawName: rawName,
      category: category,
      tvShowId: tvShowId,
      episodeNumber: cleaned.episodeNumber
    )
  }
}
