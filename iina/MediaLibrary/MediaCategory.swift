//
//  MediaCategory.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

/// Category of a media item, derived from the fixed scan subdirectory.
enum MediaCategory: Int, Codable {
  case movie = 0
  case tvShow = 1
  case other = 2

  /// The fixed subdirectory name under the media library root.
  var directoryName: String {
    switch self {
    case .movie: return "电影"
    case .tvShow: return "电视剧"
    case .other: return "其它"
    }
  }

  /// Resolve a fixed subdirectory name to a category, case-sensitively.
  static func from(directoryName: String) -> MediaCategory? {
    switch directoryName {
    case "电影": return .movie
    case "电视剧": return .tvShow
    case "其它": return .other
    default: return nil
    }
  }
}
