//
//  MediaItem.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

/// A playable video item in the media library.
///
/// `duration` is stored as `Double?` (seconds) because `VideoTime` does not conform to
/// `NSSecureCoding` and therefore cannot be persisted via `NSKeyedArchiver`. At runtime the
/// duration can be converted to `VideoTime` on demand via `VideoTime(double)`.
final class MediaItem: NSObject, NSSecureCoding {

  static var supportsSecureCoding: Bool { true }

  // MARK: Coding keys

  private enum Key {
    static let url = "MIUrl"
    static let cleanedName = "MICleanedName"
    static let rawName = "MIRawName"
    static let category = "MICategory"
    static let tvShowId = "MITvShowId"
    static let episodeNumber = "MIEpisodeNumber"
    static let duration = "MIDuration"
    static let thumbnailPath = "MIThumbnailPath"
  }

  /// File URL of the video.
  let url: URL
  /// Display name after cleaning (download-site prefix removed, etc.).
  let cleanedName: String
  /// Original file/directory name before cleaning.
  let rawName: String
  /// Category derived from the fixed scan subdirectory.
  let category: MediaCategory
  /// Identifier grouping episodes of a TV show (cleaned directory name). `nil` for movies/other.
  let tvShowId: String?
  /// 1-based episode number for TV show episodes. `nil` for movies/other.
  let episodeNumber: Int?
  /// Duration in seconds. `nil` until probed. Persisted as Double (not VideoTime).
  var duration: Double?
  /// Path to the cached thumbnail image, if generated.
  var thumbnailPath: URL?

  // MARK: Init

  init(url: URL,
       cleanedName: String,
       rawName: String,
       category: MediaCategory,
       tvShowId: String? = nil,
       episodeNumber: Int? = nil,
       duration: Double? = nil,
       thumbnailPath: URL? = nil) {
    self.url = url
    self.cleanedName = cleanedName
    self.rawName = rawName
    self.category = category
    self.tvShowId = tvShowId
    self.episodeNumber = episodeNumber
    self.duration = duration
    self.thumbnailPath = thumbnailPath
    super.init()
  }

  // MARK: NSSecureCoding

  required init?(coder: NSCoder) {
    guard let url = coder.decodeObject(of: NSURL.self, forKey: Key.url),
          let cleanedName = coder.decodeObject(of: NSString.self, forKey: Key.cleanedName),
          let rawName = coder.decodeObject(of: NSString.self, forKey: Key.rawName) else {
      return nil
    }
    let categoryRaw = coder.decodeInteger(forKey: Key.category)
    guard let category = MediaCategory(rawValue: categoryRaw) else { return nil }

    self.url = url as URL
    self.cleanedName = cleanedName as String
    self.rawName = rawName as String
    self.category = category
    self.tvShowId = coder.decodeObject(of: NSString.self, forKey: Key.tvShowId) as String?

    if coder.containsValue(forKey: Key.episodeNumber) {
      let ep = coder.decodeInteger(forKey: Key.episodeNumber)
      self.episodeNumber = ep > 0 ? ep : nil
    } else {
      self.episodeNumber = nil
    }
    if coder.containsValue(forKey: Key.duration) {
      let d = coder.decodeDouble(forKey: Key.duration)
      self.duration = d > 0 ? d : nil
    } else {
      self.duration = nil
    }
    self.thumbnailPath = coder.decodeObject(of: NSURL.self, forKey: Key.thumbnailPath) as URL?
    super.init()
  }

  func encode(with coder: NSCoder) {
    coder.encode(url as NSURL, forKey: Key.url)
    coder.encode(cleanedName as NSString, forKey: Key.cleanedName)
    coder.encode(rawName as NSString, forKey: Key.rawName)
    coder.encode(category.rawValue, forKey: Key.category)
    if let tvShowId = tvShowId {
      coder.encode(tvShowId as NSString, forKey: Key.tvShowId)
    }
    if let episodeNumber = episodeNumber {
      coder.encode(episodeNumber, forKey: Key.episodeNumber)
    }
    if let duration = duration {
      coder.encode(duration, forKey: Key.duration)
    }
    if let thumbnailPath = thumbnailPath {
      coder.encode(thumbnailPath as NSURL, forKey: Key.thumbnailPath)
    }
  }
}
