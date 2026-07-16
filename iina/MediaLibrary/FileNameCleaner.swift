//
//  FileNameCleaner.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

/// Result of cleaning a raw file/directory name.
struct FileNameCleanResult {
  /// Display name with download-site prefix and resolution/codec suffix removed.
  let cleanedName: String
  /// 1-based episode number if detected, otherwise `nil`.
  let episodeNumber: Int?
  /// TV show identifier (cleaned show name) when the name is an episode of a show, otherwise `nil`.
  let tvShowId: String?
  /// Release year if detected (4-digit, 1900–2100), otherwise `nil`.
  let year: Int?
}

/// Cleans raw video file/directory names from download-site artifacts and detects episode numbers.
///
/// Pure-local, regex-based. No network access.
enum FileNameCleaner {

  /// Download-site prefix bracket, e.g. `【高清影视之家首发 www.BBEDDE.com】`.
  private static let prefixPattern = #"【.*?www\..*?\.com】"#

  /// Tokens that mark the start of a resolution/encoding suffix. The first `.` followed by one of
  /// these tokens begins the suffix to truncate.
  private static let suffixTokens: [String] = [
    "1080p", "2160p", "720p", "480p", "4k", "WEB-DL", "WEBDL", "BluRay", "Blu-Ray", "BDRip",
    "HDRip", "HDTV", "x264", "x265", "H264", "H265", "HEVC", "AAC", "DTS", "DDP", "DDP5",
    "FLAC", "MP3", "AC3", "EAC3", "TRUEHD", "TrueHD", "MOMOWEB", "HQ-MUSIC",
  ]

  /// Promotional trailing text patterns (Chinese) to delete.
  private static let promoPatterns: [String] = [
    #"地址发布页.*"#,
    #"6v电影.*"#,
    #"最新电影.*"#,
    #"高清影视.*"#,
  ]

  /// Bracketed annotations to strip (audio/language/release tags), e.g.
  /// `[国语配音+中文字幕]`, `[全8集]`, `[GB]`. These never form part of a display title.
  /// Episode info inside brackets (e.g. `[全8集]`) is parsed separately via `episodePatterns`
  /// before this strip runs, so removing the bracket here is safe.
  private static let bracketAnnotationPattern = #"\[[^\]]*\]"#

  /// Chinese→English alias boundary: a separator (`.`/`_`/`-`/space) followed by an ASCII letter
  /// run, i.e. where a Chinese title transitions to its English alias (e.g.
  /// `本日公休.Day.Off`, `怪奇物语.第五季.Stranger.Things`). We truncate the display title here so
  /// the Chinese title is preserved without the trailing alias. Detection runs *after* episode
  /// extraction so `S05E01`/episode digits are already captured.
  private static let chineseToEnglishAliasPattern = #"[._\- ][A-Za-z]"#

  /// Episode number patterns. Captures the episode number in group 1.
  /// Order matters: `S\d+E\d+` is checked before bare `E\d+`.
  private static let episodePatterns: [(pattern: String, group: Int)] = [
    (#"[Ss](\d+)[Ee](\d+)"#, 2),
    (#"第(\d+)集"#, 1),
    (#"第(\d+)话"#, 1),
    (#"第(\d+)话"#, 1),
    (#"EP?(\d+)"#, 1),
    (#"[Ee](\d+)"#, 1),
  ]

  /// Release-year pattern: a 4-digit number in the range 1900–2100, bounded by a separator
  /// (`._ -[（(` or start/end) so it doesn't match a random 4-digit run inside a longer token.
  /// Captures the year in group 1.
  private static let yearPattern = #"(?:^|[._\- \[（(])((?:19[0-9]{2}|20[0-9]{2}|2100))(?:$|[._\- \]）)])"#

  /// Clean a raw file/directory name.
  ///
  /// - Parameter rawName: The original name (may include extension).
  /// - Returns: A `FileNameCleanResult` with `cleanedName`, `episodeNumber`, and `tvShowId`.
  ///   `tvShowId` is only set when an episode number is detected (indicating this is a TV episode);
  ///   in that case the caller is expected to use the cleaned show name as the group id.
  static func clean(_ rawName: String) -> FileNameCleanResult {
    var name = rawName

    // 0. Drop file extension if present (only for files, but harmless for dirs).
    name = (name as NSString).deletingPathExtension

    // 1. Remove download-site prefix bracket.
    if let regex = try? NSRegularExpression(pattern: prefixPattern, options: []) {
      name = regex.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: name.utf16.count), withTemplate: "")
    }

    // 2. Remove promotional trailing text.
    for pattern in promoPatterns {
      if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
        name = regex.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: name.utf16.count), withTemplate: "")
      }
    }

    // 2b. Strip bracketed annotations (audio/language/release tags like `[国语配音+中文字幕]`).
    //     Safe wrt episode detection: step 3 (below) runs AFTER this strip, but episode markers
    //     (`S05E01` / `第N集` / `EN`) live outside `[...]` brackets in practice, so stripping the
    //     brackets does not lose episode info.
    if let regex = try? NSRegularExpression(pattern: bracketAnnotationPattern, options: []) {
      name = regex.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: name.utf16.count), withTemplate: "")
    }

    // 3. Detect episode number (before suffix truncation, as patterns may contain dots/numbers).
    var episodeNumber: Int? = nil
    for spec in episodePatterns {
      if let regex = try? NSRegularExpression(pattern: spec.pattern, options: []) {
        let range = NSRange(location: 0, length: name.utf16.count)
        if let match = regex.firstMatch(in: name, options: [], range: range),
           match.numberOfRanges > spec.group,
           let range = Range(match.range(at: spec.group), in: name),
           let n = Int(name[range]), n > 0 {
          episodeNumber = n
          break
        }
      }
    }

    // 4. Detect release year (1900–2100, bounded by separators) before suffix truncation so a
    //    year token at the suffix boundary isn't lost.
    var year: Int? = nil
    if let regex = try? NSRegularExpression(pattern: yearPattern, options: []) {
      let range = NSRange(location: 0, length: name.utf16.count)
      if let match = regex.firstMatch(in: name, options: [], range: range),
         match.numberOfRanges > 1,
         let yRange = Range(match.range(at: 1), in: name),
         let y = Int(name[yRange]) {
        year = y
      }
    }

    // 5. Truncate at resolution/encoding suffix. Tokens may be separated by `.` or `[` or ` ` or `_`.
    //    We look for the first occurrence of any token preceded by a separator (or at start).
    let lowercased = name.lowercased()
    var cutIndex: String.Index? = nil
    for token in suffixTokens {
      let needle = token.lowercased()
      // Search for `.<token>`, `_<token>`, ` <token>`, `[<token>`, or start-of-string.
      let variants = [".\(needle)", "_\(needle)", " \(needle)", "[\(needle)", "［\(needle)"]
      for variant in variants {
        if let range = lowercased.range(of: variant) {
          let idx = range.lowerBound
          if cutIndex == nil || idx < cutIndex! {
            cutIndex = idx
          }
        }
      }
      // Also handle token at very start (rare).
      if lowercased.hasPrefix(needle) {
        let idx = name.startIndex
        if cutIndex == nil || idx < cutIndex! {
          cutIndex = idx
        }
      }
    }
    if let cut = cutIndex {
      name = String(name[name.startIndex..<cut])
    }

    // 5b. Truncate Chinese→English alias boundary: when a CJK title is followed by a separator
    //     and an ASCII-letter run (the English alias, e.g. `本日公休.Day.Off`, `怪奇物语.Stranger`),
    //     keep only the leading CJK portion. This runs after suffix truncation and only fires
    //     when the name still contains CJK characters (so a pure-English name is untouched).
    //     We require a CJK char to precede the boundary so a leading English word isn't cut.
    if let regex = try? NSRegularExpression(pattern: chineseToEnglishAliasPattern, options: []),
       name.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
      let range = NSRange(location: 0, length: name.utf16.count)
      if let match = regex.firstMatch(in: name, options: [], range: range),
         let boundary = Range(match.range, in: name),
         boundary.lowerBound > name.startIndex {
        // Only cut if the character immediately before the separator-and-letter is CJK,
        // confirming a CJK→English transition (not a separator inside an English token).
        // The `> startIndex` guard avoids `index(before: startIndex)` crash when a sep+letter
        // match lands at the very start of the string (no preceding char to check).
        let preBoundaryIdx = name.index(before: boundary.lowerBound)
        let preChar = String(name[preBoundaryIdx])
        if preChar.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
          name = String(name[name.startIndex..<boundary.lowerBound])
        }
      }
    }

    // 6. Trim brackets/whitespace/separators at both ends.
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ._-[]【】()（）"))
    // Collapse a leading/trailing dot-run left by truncation.
    while name.hasPrefix(".") || name.hasPrefix("_") || name.hasPrefix("-") {
      name = String(name.dropFirst())
    }
    while name.hasSuffix(".") || name.hasSuffix("_") || name.hasSuffix("-") {
      name = String(name.dropLast())
    }
    name = name.trimmingCharacters(in: .whitespaces)

    // 7. If episode detected, set tvShowId to the cleaned name (caller may override with dir name).
    let tvShowId: String? = episodeNumber != nil ? name : nil

    // 8. Fallback: if everything got stripped, use the original (minus extension).
    if name.isEmpty {
      name = (rawName as NSString).deletingPathExtension
    }

    return FileNameCleanResult(cleanedName: name, episodeNumber: episodeNumber, tvShowId: tvShowId, year: year)
  }

  /// Clean a name intended for display only (no episode/tvShow extraction). Used for TV show
  /// directory names where the whole name represents the show.
  static func cleanShowName(_ rawName: String) -> String {
    let result = clean(rawName)
    // For a directory name we want the show title without episode markers.
    return result.cleanedName
  }
}
