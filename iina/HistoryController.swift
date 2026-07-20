//
//  HistoryController.swift
//  iina
//
//  Created by lhc on 25/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class HistoryController: NSObject {

  static let shared = HistoryController(plistFileURL: Utility.playbackHistoryURL)

#if DEBUG
  /// As logging of all history entries can produce a huge number of log messages this feature is only included in debug builds and
  /// must be enabled by setting this property to `true` when you need investigate history file contents.
  private static let logAllHistoryEntries = false
#endif

  /// Cached copy of the playback history stored in the history file.
  ///
  /// This is accessed by both the main thread and a background thread and must be referenced under a lock.
  @Atomic var history: [PlaybackHistory] = []

  /// Number of tasks currently in the queue.
  @Atomic var tasksOutstanding = 0

  private let plistURL: URL
  private let queue = DispatchQueue(label: "IINAHistoryController", qos: .background)

  init(plistFileURL: URL) {
    self.plistURL = plistFileURL
    super.init()
    read()
  }

  private func read() {
    // Avoid logging a scary error if the file does not exist.
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
    do {
      MemoryUsage.shared.logUsage("before reading history")
      let data = try Data(contentsOf: plistURL)
      let object = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, PlaybackHistory.self],
                                                          from: data)
      guard let history = object as? [PlaybackHistory] else {
        // Secure coding should ensure that this never occurs.
        log("Unable to convert object read from playback history file to [PlaybackHistory]", level: .error)
        return
      }
      self.history = history
      log("Read \(history.count) playback history entries")
      MemoryUsage.shared.logUsage("after reading history")

      // As logging of all history entries can produce a huge number of log messages this feature is
      // only included in debug builds.
#if DEBUG
      // IINA must be built with the property logAllHistoryEntries set to true when you want the
      // history file contents to be logged when it is read.
      guard HistoryController.logAllHistoryEntries, !history.isEmpty,
            Logger.isEmitting(.verbose) else { return }
      log("Playback history:", level: .verbose)
      var index = 0
      for entry in history {
        log("History[\(index)] \(String(describing: entry))", level: .verbose)
        index += 1
      }
#endif
    } catch {
      log("Failed to read playback history file \(plistURL.path): \(error)", level: .error)
    }
  }

  private func save() {
    do {
      try $history.withLock { history in
        log("Saving \(history.count) playback history entries")
        let data = try NSKeyedArchiver.archivedData(withRootObject: history, requiringSecureCoding: true)
        try data.write(to: plistURL, options: [.atomic])
        log("Saved \(history.count) playback history entries")
      }
      NotificationCenter.default.post(Notification(name: .iinaHistoryUpdated))
    } catch {
      log("Failed to save playback history to file \(plistURL.path): \(error)", level: .error)
    }
  }

  /// Add an entry to playback history.
  /// - Note: The entry is added asynchronously by a background thread.
  /// - Important: 修复 A3：若同 mpvMd5 的旧 entry 已有 mpvProgress（由 updateProgress 回写），
  ///   新 entry 必须继承，禁止被 init 默认 nil 覆盖（否则继续观看的历史进度会丢失）。
  /// - Parameters:
  ///   - url: URL of the media being played.
  ///   - duration: Total duration of the media.
  ///   - title: Title of the media (if available).
  ///   - ignorePath: When `true`, only the URL's filename will be used for the sum if the URL does not contain a scheme.
  func add(_ url: URL, duration: Double, title: String?, _ ignorePath: Bool) {
    guard Preference.bool(for: .recordPlaybackHistory) else { return }
    $tasksOutstanding.withLock { $0 += 1 }
    queue.async { [self] in
      let mpvMd5 = Utility.mpvWatchLaterMd5(url, ignorePath)
      $history.withLock { history in
        // 修复 A3：remove 旧条目前先抓取其 mpvProgress，迁移到新 entry。
        var inheritedProgress: VideoTime? = nil
        if let existingItem = history.first(where: { $0.mpvMd5 == mpvMd5 }),
           let index = history.firstIndex(of: existingItem) {
          inheritedProgress = existingItem.mpvProgress
          history.remove(at: index)
        }
        let entry = PlaybackHistory(url: url, duration: duration, title: title, mpvMd5: mpvMd5)
        // 迁移旧 entry 的 mpvProgress（updateProgress 写入的 IINA 自维护进度源）。
        if let progress = inheritedProgress, progress.second > 0 {
          entry.mpvProgress = progress
        }
        history.insert(entry, at: 0)
        log("Adding to history: \(String(describing: entry))", level: .verbose)
      }
      save()
      $tasksOutstanding.withLock { tasksOutstanding in
        tasksOutstanding -= 1
        if tasksOutstanding != 0 {
          // The history controller must be able to finish saving playback history before IINA
          // terminates or history will be lost. If termination times out before saving of playback
          // history has finished then history will be lost. If that happens then the qos of the
          // history batch queue will need to be raised to allow the history controller to keep up
          // with requests to save history.
          log("History tasks outstanding: \(tasksOutstanding)")
        }
      }
      NotificationCenter.default.post(Notification(name: .iinaHistoryTaskFinished))
    }
  }

  /// 修复 A2/A3 / C1：更新已存在 entry 的 mpvProgress（IINA 自维护的独立进度源）。
  ///
  /// PlayerCore.savePlaybackPosition 在 mpv `savePositionOnQuit` 关闭时也调用此方法，
  /// 确保 watch-later 写失败时仍有 fallback。复用 `add` 的 `queue.async` + `$history.withLock`
  /// 调度（TSan 安全来自加锁而非主线程同步写）。
  ///
  /// - Important: 对不存在的 entry 静默跳过（不创建新条目——`add` 负责 entry 创建）。
  /// - Parameters:
  ///   - url: 已在 history 中的 media URL。
  ///   - progress: 新的播放进度。
  func updateProgress(url: URL, progress: VideoTime) {
    $tasksOutstanding.withLock { $0 += 1 }
    queue.async { [self] in
      $history.withLock { history in
        guard let index = history.firstIndex(where: { $0.url == url }) else { return }
        history[index].mpvProgress = progress
        log("Updated mpvProgress for \(url.lastPathComponent): \(progress.second)s", level: .verbose)
      }
      save()
      $tasksOutstanding.withLock { $0 -= 1 }
      NotificationCenter.default.post(Notification(name: .iinaHistoryTaskFinished))
    }
  }

  /// 测试 seam：阻塞直到 `queue` 中所有任务完成（add/updateProgress 落盘）。
  /// 仅供单元测试调用，避免异步竞争。生产代码不应依赖此方法。
  func waitForDrain() {
    queue.sync { }
  }

  func remove(_ entries: [PlaybackHistory]) {
    $history.withLock { history in
      log("Removing \(entries.count) playback history entries")
      history = history.filter { !entries.contains($0) }
    }
    save()
  }

  func removeAll() {
    $history.withLock { history in
      log("Removing all playback history entries")
      history = []
    }
    save()
  }

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.history)
  }
}

extension Logger.Sub {
  static let history = Logger.makeSubsystem("history", ["clock"])
}
