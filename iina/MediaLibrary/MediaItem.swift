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
    // New metadata fields (P0.4). Decoded with `containsValue` for backward compatibility —
    // older index.plist files without these keys decode to nil without crashing.
    static let year = "MIYear"
    static let width = "MIWidth"
    static let height = "MIHeight"
    static let videoCodec = "MIVideoCodec"
    static let bitrate = "MIBitrate"
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
  /// Release year parsed from the filename (1900–2100). `nil` if not detected.
  var year: Int?
  /// Video stream width in pixels (lazily probed via libavformat). `nil` until probed.
  var width: Int?
  /// Video stream height in pixels (lazily probed). `nil` until probed.
  var height: Int?
  /// Video codec name (e.g. `h264`, `hevc`), lazily probed. `nil` until probed.
  var videoCodec: String?
  /// Overall bit rate in bps, lazily probed. `nil` until probed.
  var bitrate: Int?

  // MARK: Init

  init(url: URL,
       cleanedName: String,
       rawName: String,
       category: MediaCategory,
       tvShowId: String? = nil,
       episodeNumber: Int? = nil,
       duration: Double? = nil,
       thumbnailPath: URL? = nil,
       year: Int? = nil,
       width: Int? = nil,
       height: Int? = nil,
       videoCodec: String? = nil,
       bitrate: Int? = nil) {
    self.url = url
    self.cleanedName = cleanedName
    self.rawName = rawName
    self.category = category
    self.tvShowId = tvShowId
    self.episodeNumber = episodeNumber
    self.duration = duration
    self.thumbnailPath = thumbnailPath
    self.year = year
    self.width = width
    self.height = height
    self.videoCodec = videoCodec
    self.bitrate = bitrate
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
      // Distinguish "no value" (key absent → nil) from a real duration of 0.0.
      // A media file may legitimately have duration 0.0 (e.g. still being probed), and the
      // `containsValue` guard above already handles the "absent → nil" case, so 0.0 must
      // round-trip as 0.0 rather than collapsing to nil.
      self.duration = coder.decodeDouble(forKey: Key.duration)
    } else {
      self.duration = nil
    }
    self.thumbnailPath = coder.decodeObject(of: NSURL.self, forKey: Key.thumbnailPath) as URL?
    // New metadata fields: decode with containsValue guard for backward compatibility.
    if coder.containsValue(forKey: Key.year) {
      let y = coder.decodeInteger(forKey: Key.year)
      self.year = (y >= 1900 && y <= 2100) ? y : nil
    } else {
      self.year = nil
    }
    if coder.containsValue(forKey: Key.width) {
      let w = coder.decodeInteger(forKey: Key.width)
      self.width = w > 0 ? w : nil
    } else {
      self.width = nil
    }
    if coder.containsValue(forKey: Key.height) {
      let h = coder.decodeInteger(forKey: Key.height)
      self.height = h > 0 ? h : nil
    } else {
      self.height = nil
    }
    self.videoCodec = coder.containsValue(forKey: Key.videoCodec)
      ? coder.decodeObject(of: NSString.self, forKey: Key.videoCodec) as String?
      : nil
    if coder.containsValue(forKey: Key.bitrate) {
      let br = coder.decodeInteger(forKey: Key.bitrate)
      self.bitrate = br > 0 ? br : nil
    } else {
      self.bitrate = nil
    }
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
    if let year = year {
      coder.encode(year, forKey: Key.year)
    }
    if let width = width {
      coder.encode(width, forKey: Key.width)
    }
    if let height = height {
      coder.encode(height, forKey: Key.height)
    }
    if let videoCodec = videoCodec {
      coder.encode(videoCodec as NSString, forKey: Key.videoCodec)
    }
    if let bitrate = bitrate {
      coder.encode(bitrate, forKey: Key.bitrate)
    }
  }
}
