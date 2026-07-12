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

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  /// Scan the root directory and return all discovered media items.
  ///
  /// - Parameter root: Root URL containing the three fixed subdirectories.
  /// - Returns: Array of `MediaItem`. Empty if subdirectories exist but contain no videos.
  /// - Throws: `MediaLibraryError.pathNotAccessible` if the root is not readable;
  ///   `MediaLibraryError.scanFailed` on I/O errors.
  func scan(root: URL) throws -> [MediaItem] {
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
          }
        } else if isVideoFile(entryURL) {
          items.append(makeItem(url: entryURL, category: category, tvShowId: nil))
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
        } else if isVideoFile(subURL) {
          // A stray video file directly under 电视剧 (not in a show dir): treat as a standalone.
          items.append(makeItem(url: subURL, category: .tvShow, tvShowId: nil))
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
