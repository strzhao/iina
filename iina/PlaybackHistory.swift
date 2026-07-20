//
//  PlaybackHistory.swift
//  iina
//
//  Created by lhc on 28/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let KeyUrl = "IINAPHUrl"
fileprivate let KeyName = "IINAPHNme"
fileprivate let KeyMpvMd5 = "IINAPHMpvmd5"
fileprivate let KeyPlayed = "IINAPHPlayed"
fileprivate let KeyAddedDate = "IINAPHDate"
fileprivate let KeyDuration = "IINAPHDuration"
fileprivate let KeyTitle = "IINAPHTitle"
/// IINA 自持久化的独立播放进度（seconds, Double）。
/// 设计偏差：VideoTime 不是 NSSecureCoding，故 encode 为 Double（与 KeyDuration 一致）。
/// 修复 A1：mpvProgress 不再只是 watch-later 的派生镜像，而是 IINA 独立持久化的进度源，
/// 当 watch-later 文件缺失/被覆盖（mpv pos=NOPTS、NAS I/O 时序）时提供 fallback。
fileprivate let KeyMpvProgress = "IINAPHMpvProgress"

/// An entry in the playback history file.
/// - Important: This class conforms to [NSSecureCoding](https://developer.apple.com/documentation/foundation/nssecurecoding).
///     When making changes be certain the requirements for secure coding are not violated by the changes.
class PlaybackHistory: NSObject, NSSecureCoding {

  /// Indicate this class supports secure coding.
  static var supportsSecureCoding: Bool { true }

  private static let dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
    return dateFormatter
  }()

  var url: URL
  var name: String
  var mpvMd5: String

  var played: Bool
  var addedDate: Date

  var duration: VideoTime
  var mpvProgress: VideoTime?

  var title: String?

  /// A description of this playback history entry suitable to include in a log message.
  override var description: String {
    var description = """
      added: \(PlaybackHistory.dateFormatter.string(from: addedDate)) \
      duration: \(duration.stringRepresentation)
      """
    if let mpvProgress { description += " progress: \(mpvProgress.stringRepresentation)" }
    description += "\n  \(url)"
    if let title { description += "\n  \(title)" }
    description += "\n  MD5: \(mpvMd5)"
    return description
  }

  required init?(coder aDecoder: NSCoder) {
    guard
      let url = aDecoder.decodeObject(of: NSURL.self, forKey: KeyUrl),
      let name = aDecoder.decodeObject(of: NSString.self, forKey: KeyName),
      let md5 = aDecoder.decodeObject(of: NSString.self, forKey: KeyMpvMd5),
      let date = aDecoder.decodeObject(of: NSDate.self, forKey: KeyAddedDate)
    else {
      return nil
    }

    let played = aDecoder.decodeBool(forKey: KeyPlayed)
    let duration = aDecoder.decodeDouble(forKey: KeyDuration)
    let title = aDecoder.decodeObject(of: NSString.self, forKey: KeyTitle)

    self.url = url as URL
    self.name = name as String
    self.mpvMd5 = md5 as String
    self.played = played
    self.addedDate = date as Date
    self.duration = VideoTime(duration)
    self.title = title as String?

    // 修复 A1：优先 decode IINA 自持久化的 mpvProgress（KeyMpvProgress, Double seconds）。
    // containsValueForKey 区分"键存在" vs "键缺失（旧 plist）"：
    //   - 旧 plist（无 KeyMpvProgress）：fallback 到 watch-later 读取，保持旧行为。
    //   - 新 plist 含 KeyMpvProgress：用持久化值（> 0；0 或负数视作无效，fallback watch-later）。
    if aDecoder.containsValue(forKey: KeyMpvProgress),
       let secBox = aDecoder.decodeObject(of: NSNumber.self, forKey: KeyMpvProgress) as? NSNumber {
      let sec = secBox.doubleValue
      self.mpvProgress = sec > 0 ? VideoTime(sec) : Utility.playbackProgressFromWatchLater(self.mpvMd5)
    } else {
      // 向后兼容：旧 plist 无 KeyMpvProgress，fallback 现 watch-later 逻辑。
      self.mpvProgress = Utility.playbackProgressFromWatchLater(self.mpvMd5)
    }
  }

  init(url: URL, duration: Double, name: String? = nil, title: String?, mpvMd5: String) {
    self.url = url
    self.name = name ?? url.lastPathComponent
    self.mpvMd5 = mpvMd5
    self.played = true
    self.addedDate = Date()
    self.duration = VideoTime(duration)
    self.title = title
  }

  func encode(with aCoder: NSCoder) {
    aCoder.encode(url, forKey: KeyUrl)
    aCoder.encode(name, forKey: KeyName)
    aCoder.encode(mpvMd5, forKey: KeyMpvMd5)
    aCoder.encode(played, forKey: KeyPlayed)
    aCoder.encode(addedDate, forKey: KeyAddedDate)
    aCoder.encode(duration.second, forKey: KeyDuration)
    aCoder.encode(title, forKey: KeyTitle)
    // 修复 A1：持久化 IINA 自维护的 mpvProgress（独立于 mpv watch-later）。
    // 只在 mpvProgress 非 nil 且 > 0 时写入（避免 encode(0) 被 NSCoder 当作 Int 导致 decodeDouble 失败）。
    // 缺失该键时 decode 路径走 fallback（watch-later），保持旧 plist 向后兼容。
    if let progress = mpvProgress, progress.second > 0 {
      aCoder.encode(NSNumber(value: progress.second), forKey: KeyMpvProgress)
    }
  }
}
