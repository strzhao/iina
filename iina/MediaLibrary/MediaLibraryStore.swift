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

/// 主线程构建的「继续观看」候选快照：一条 playback-history entry 匹配到一个 `MediaItem`，
/// 并把后台计算所需的值字段预提取为值类型。
///
/// 设计目的：后台去重/排序 pass 只碰值类型，不碰主线程持有的容器（`history`/`items`/`md5Index`）
/// 与 `MediaItem`/`PlaybackHistory` 的 var 字段（`duration`/`thumbnailPath`/`mpvProgress`），
/// 消除数据竞争。`item` 引用仅为 cell 缩略图/点击携带——后台代码不得读其 var 属性，所需字段已
/// 在此预提取（`durationSec`/`fallbackProgressSec` 等）。
struct ContinueWatchingCandidate {
  let mpvMd5: String
  let item: MediaItem
  let tvShowId: String?
  let urlPath: String
  let addedDate: Date
  let durationSec: Double
  let episodeNumber: Int?
  let cleanedName: String
  /// IINA 自持久化 fallback 进度（`entry.mpvProgress?.second`），主线程预提取。
  /// 后台 watch-later 读不到时回退到此值（覆盖 mpv 写失败 / NAS I/O 时序场景）。
  let fallbackProgressSec: Double?
}

/// 后台产出、主线程消费的「继续观看」卡片：代表 `MediaItem` + 预算好的进度/时长/显示名。
/// cell 拿到 entry 后**零 watch-later IO**——进度已在后台算好（主线程 IO 从 N+10 降到 0）。
struct ContinueWatchingEntry {
  let item: MediaItem
  let progressSec: Double
  let durationSec: Double
  let displayName: String

  /// 进度条填充比例（0...1，已 clamp）。
  var progressRatio: Double {
    guard durationSec > 0 else { return 0 }
    return min(max(progressSec / durationSec, 0), 1)
  }

  /// 剩余秒数（卡片「剩 mm:ss」徽标）。
  var remainingSec: Double {
    return max(durationSec - progressSec, 0)
  }
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

  /// P3：后台 `loadIndexAsync` 完成后 post（object = store）。VC 监听 → refresh 显示加载完的缓存。
  static let indexLoadedNotification = Notification.Name("iinaMediaLibraryIndexLoaded")

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

  /// Path to the persisted index plist. Under `-iinaTestDataRoot` (XCUI tests) this redirects to
  /// the test data root so `saveIndex()` never writes the production plist (test-isolation seam;
  /// see `Utility.testDataRootURL`).
  private let indexURL: URL = {
    if let root = Utility.testDataRootURL {
      return root.appendingPathComponent("media_library_index.plist", isDirectory: false)
    }
    return Utility.appSupportDirUrl.appendingPathComponent("media_library_index.plist", isDirectory: false)
  }()

  /// Background queue for scanning.
  private let scanQueue = DispatchQueue(label: "iina.media.library.scan", qos: .userInitiated)

  /// P1 后台写盘队列。编码留主线程（items 只在主线程改，后台编码会数据竞争），仅 `data.write`
  /// 入此队列（qos .utility 不抢占用户交互）。
  private let saveQueue = DispatchQueue(label: "iina.media.library.save", qos: .utility)
  /// P1 合并写窗口（s）。与 metadataProbed coalesce 一致。
  private let saveCoalesceInterval: TimeInterval = 0.1
  /// P1 脏标记（仅主线程访问）。
  private var saveIndexDirty: Bool = false
  /// P1 合并调度标志（仅主线程访问）。
  private var saveFlushScheduled: Bool = false
  /// P1 seam：saveQueue 写盘次数（`lock` 守护）。红队测 P1.3 合并（N≥8 变更 → ≤4 && <N）。
  internal private(set) var saveWriteCount: Int = 0
  /// P1 守护 saveWriteCount 的锁。
  private let saveWriteLock = NSLock()

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

  /// P3：后台 loadIndexAsync 进行中。仅主线程读写。VC refresh 据此显示「加载中…」占位。
  internal private(set) var isLoadingIndex: Bool = false
  /// P3 / B1：rescan 统一闸门。`isLoadingIndex` 期间的 rescan 调用排队（合并为一次），由
  /// `loadIndexAsync` 完成块末尾放行。覆盖所有 rescan 调用点（viewDidLoad 首启 +
  /// PrefMediaLibraryViewController:121 改路径），不依赖调用点改造。仅主线程读写。
  private var pendingRescan: Bool = false
  /// P3 seam：记录反序列化完成线程（红队 P3.1 断言 isMainThread == false）。
  internal var __test_lastIndexLoadThread: Thread?
  /// A.2 seam：记录「继续观看」后台计算线程（红队断言 isMainThread == false，验证后台化）。
  /// 主线程写、后台捕获（与 `__test_lastIndexLoadThread` 同构，TSan 安全）。
  internal var __test_lastContinueWatchingComputeThread: Thread?

  /// 测试隔离 seam（auto-fix）：禁 rescan 避免 hosted XCTest 构造 VC（viewDidLoad）时扫真 NAS
  /// （默认 rootPath 指向绿联 NAS 挂载点，rescan 异步完成会覆盖 setItemsForTesting）。
  /// 生产恒 false；红队测试构造 VC 前设 true。仅跳过扫描，不影响 loadIndex/通知/P3.5（通知模拟）。
  internal static var disableRescanForTesting: Bool = false

  private override init() {
    super.init()
    // P3：不再同步 loadIndex()（主线程阻塞首屏）。设 isLoadingIndex 后台加载，首屏占位先于
    // 反序列化完成可交互。
    isLoadingIndex = true
    loadIndexAsync()
    // P1.5：退出前同步 flush 兜底，防 0.1s 合并窗口内的变更丢失（强杀/崩溃丢最近窗口可接受：
    // index.plist 仅缓存，下次 rescan 重建）。
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleWillTerminate),
      name: NSApplication.willTerminateNotification, object: nil)
  }

  /// P1.5：退出前 flushNow 兜底。
  @objc private func handleWillTerminate() {
    flushNow()
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
    // 测试隔离（auto-fix）：禁 rescan 避免扫真 NAS（红队 disableRescanForTesting=true 时）。
    if Self.disableRescanForTesting { return }
    // P3 / B1：统一闸门。isLoadingIndex 期间所有 rescan 调用点（viewDidLoad 首启 +
    // PrefMediaLibraryViewController:121 改路径）排队，由 loadIndexAsync 完成块放行。
    // 保证 rescan 失败时保留的是真实缓存（[2026-07-13] 后台扫描失败保留缓存），非空集。
    // 多次排队合并为 loadIndex 完成后一次最新路径扫描（pendingRescan 为 bool）。
    if isLoadingIndex {
      pendingRescan = true
      return
    }
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
          // P1：合并写（0.1s 窗口），替换原 saveIndex()。
          self.scheduleSaveIndex()
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
      // P4：用预计算的 cleanedNameLowercased，避免每次 filter 重复全表 lowercased()。
      result = result.filter { $0.cleanedNameLowercased.contains(needle) }
    }
    return result
  }

  /// Items with playback progress < 95% of duration, sorted by last-played, **deduped per TV show**,
  /// limited to 10. Synchronous wrapper over `continueWatchingCandidates()` +
  /// `continueWatchingEntries(from:)` for low-frequency callers (startup/scan `refresh()`).
  ///
  /// `played` is intentionally not consulted: `HistoryController.add` hardcodes `played=true` on
  /// every entry, so filtering on it would exclude the entire history.
  func continueWatchingItems() -> [MediaItem] {
    return continueWatchingEntries(from: continueWatchingCandidates()).map { $0.item }
  }

  /// 主线程快照：遍历 `HistoryController` history（`$history.withLock` 安全取 copy），匹配每个
  /// entry 到 `MediaItem`（`md5Index` 优先，降级全量扫描），预提取后台所需的值字段。
  ///
  /// 主线程契约：history 走 `@Atomic` 的 `withLock`（与 `save()` 同构），`items`/`md5Index` 主线程读。
  /// var-来源字段（`entry.mpvProgress?.second`、`item.duration`）在此预提取为值类型，后台不再碰
  /// `PlaybackHistory`/`MediaItem` 的可变属性，消除数据竞争。
  func continueWatchingCandidates() -> [ContinueWatchingCandidate] {
    let ignorePath = currentIgnorePath()
    let historySnapshot: [PlaybackHistory] = HistoryController.shared.$history.withLock { $0 }
    var out: [ContinueWatchingCandidate] = []
    out.reserveCapacity(historySnapshot.count)
    for entry in historySnapshot {
      // Match by md5 first (cached), then by full scan.
      var matched: MediaItem? = md5Index[entry.mpvMd5]
      if matched == nil {
        matched = items.first { Utility.mpvWatchLaterMd5($0.url, ignorePath) == entry.mpvMd5 }
      }
      guard let item = matched else { continue }
      // Duration guard（廉价，留主线程）。
      let durationSec: Double
      if let d = item.duration { durationSec = d }
      else if entry.duration.second > 0 { durationSec = entry.duration.second }
      else { continue }
      out.append(ContinueWatchingCandidate(
        mpvMd5: entry.mpvMd5,
        item: item,
        tvShowId: item.tvShowId,
        urlPath: item.url.path,
        addedDate: entry.addedDate,
        durationSec: durationSec,
        episodeNumber: item.episodeNumber,
        cleanedName: item.cleanedName,
        fallbackProgressSec: entry.mpvProgress?.second
      ))
    }
    return out
  }

  /// 后台纯函数：对每个 candidate 读 watch-later（`playbackProgressFromWatchLater` 优先，
  /// `fallbackProgressSec` 回退）→ 过滤 `progressSec>0` 与 watchedThreshold → 按 `tvShowId`
  /// 聚合去重（同剧只留 addedDate 最新且合法的代表）→ 按 addedDate 降序 → 截断到
  /// `continueWatchingLimit` → 组装 `displayName`。
  ///
  /// 无主线程依赖（watch-later 读是纯文件 IO，candidates 是值类型快照），可后台、可单测。
  /// 进度读取顺序与 `progress(for:)` 一致（watch-later 优先 + mpvProgress 回退），保持一致性契约。
  func continueWatchingEntries(from candidates: [ContinueWatchingCandidate]) -> [ContinueWatchingEntry] {
    // dedupeKey → (candidate, progressSec)，存「该 key 内 addedDate 最新且合法」的代表。
    var bestByKey: [String: (candidate: ContinueWatchingCandidate, progressSec: Double)] = [:]
    for cand in candidates {
      var progressSec: Double? = Utility.playbackProgressFromWatchLater(cand.mpvMd5)?.second
      if progressSec == nil { progressSec = cand.fallbackProgressSec }
      guard let p = progressSec, p > 0 else { continue }
      if p >= cand.durationSec * MediaLibraryStore.watchedThreshold { continue }
      // dedupeKey：剧集按 tvShowId（同剧多集合并为单入口），单文件按自身路径（各自独立）。
      let key = cand.tvShowId ?? cand.urlPath
      if let existing = bestByKey[key] {
        if cand.addedDate > existing.candidate.addedDate {
          bestByKey[key] = (cand, p)
        }
      } else {
        bestByKey[key] = (cand, p)
      }
    }
    let sorted = bestByKey.values.sorted { $0.candidate.addedDate > $1.candidate.addedDate }
    return Array(sorted.prefix(MediaLibraryStore.continueWatchingLimit)).map { pair in
      ContinueWatchingEntry(
        item: pair.candidate.item,
        progressSec: pair.progressSec,
        durationSec: pair.candidate.durationSec,
        displayName: MediaLibraryStore.continueWatchingDisplayName(for: pair.candidate)
      )
    }
  }

  /// 组装卡片显示名：剧集 = 「剧名 · 第N集」（无集数则仅剧名），电影/单文件 = cleanedName。
  /// 后台预算（廉价字符串拼接），零主线程成本。
  private static func continueWatchingDisplayName(for cand: ContinueWatchingCandidate) -> String {
    if let show = cand.tvShowId {
      if let ep = cand.episodeNumber {
        return "\(show) · 第\(ep)集"
      }
      return show
    }
    return cand.cleanedName
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
      // P4：用预计算的 cleanedNameLowercased。
      groups = groups.filter { $0.representative.cleanedNameLowercased.contains(needle) }
    }
    groups.sort { $0.representative.cleanedName < $1.representative.cleanedName }
    return groups
  }

  /// Playback progress (seconds) for a media item, read LIVE from watch-later. Returns nil if no
  /// watch-later file / no `start=`. Reading live (rather than `entry.mpvProgress`, a startup
  /// snapshot) keeps card progress bars current after new playback without restarting.
  ///
  /// 修复 A4 / C2：watch-later 读不到时 fallback 到 entry.mpvProgress?.second（独立进度源），
  /// 覆盖 mpv 写 watch-later 失败（NAS I/O 时序 / pos=NOPTS）场景。
  func progress(for item: MediaItem) -> Double? {
    let ignorePath = currentIgnorePath()
    let md5 = Utility.mpvWatchLaterMd5(item.url, ignorePath)
    if let live = Utility.playbackProgressFromWatchLater(md5)?.second {
      return live
    }
    // Fallback：通过 md5 找 history entry，读 IINA 自持久化的 mpvProgress。
    let history = HistoryController.shared.history
    if let entry = history.first(where: { $0.mpvMd5 == md5 }) {
      return entry.mpvProgress?.second
    }
    return nil
  }

  // MARK: Persistence

  /// Load the cached index from disk (best-effort; corrupt/missing → empty).
  /// 保留同步版本供测试夹具或未来场景显式调用；生产 init 用 `loadIndexAsync`。
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

  /// P3：后台反序列化 → 主线程 setItems + post + 放行 pendingRescan。复用 rescan 的
  /// 「后台产出 → 主线程 setItems」模式。反序列化失败（corrupt/missing）→ items = [] +
  /// rebuildIndices（与 loadIndex catch 一致）。
  private func loadIndexAsync() {
    let url = indexURL
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      // 后台产出，不碰现有 items。
      var arr: [MediaItem] = []
      if FileManager.default.fileExists(atPath: url.path) {
        do {
          let data = try Data(contentsOf: url)
          let object = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, MediaItem.self], from: data)
          if let decoded = object as? [MediaItem] {
            arr = decoded
          }
        } catch {
          // Corrupt index — start fresh（与 loadIndex catch 一致）。
          arr = []
        }
      }
      // P3 seam：捕获后台反序列化线程（此处为后台线程）；写 seam 移到主线程避免与测试主线程读 race（TSan）。
      let deserializeThread = Thread.current
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.__test_lastIndexLoadThread = deserializeThread
        self.items = arr
        self.rebuildIndices()
        self.isLoadingIndex = false
        NotificationCenter.default.post(
          name: MediaLibraryStore.indexLoadedNotification, object: self)
        // P3 / B1：放行 pendingRescan。闸门期间排队的 rescan 在此执行（最新路径）。
        if self.pendingRescan {
          self.pendingRescan = false
          self.rescan()
        }
      }
    }
  }

  /// 测试 seam（auto-fix P3.3）：重新触发 loadIndexAsync，供红队干净测「加载 item 数 == plist」，
  /// 避免其他测试 setItemsForTesting 的单例污染（单例只在 init 时 loadIndexAsync 一次，之后 store.items
  /// 被污染无法干净测）。仅测试用：重置 isLoadingIndex=true + loadIndexAsync（从 indexURL 重新反序列化）。
  internal func reloadIndexForTesting() {
    isLoadingIndex = true
    loadIndexAsync()
  }

  /// P1：主线程标记 dirty + 0.1s 合并调度。替换所有 `saveIndex()` 调用点。窗口内多次
  /// schedule 合并为 1 次编码 + 1 次写盘（红队 P1.3）。
  internal func scheduleSaveIndex() {
    saveIndexDirty = true
    guard !saveFlushScheduled else { return }
    saveFlushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + saveCoalesceInterval) { [weak self] in
      self?.flushSaveIndex()
    }
  }

  /// P1：主线程 flush（由 asyncAfter 调度）。编码留主线程（items 只在主线程改），仅 `data.write`
  /// 入 saveQueue。
  private func flushSaveIndex() {
    saveFlushScheduled = false
    guard saveIndexDirty else { return }
    saveIndexDirty = false
    // 主线程编码（无数据竞争）。
    let data = try? NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: true)
    let url = indexURL
    saveQueue.async { [weak self] in
      try? data?.write(to: url, options: [.atomic])
      self?.recordSaveWrite()
    }
  }

  /// P1：同步编码 + 同步写（主线程），退出/测试用。重置 dirty/调度标志。
  internal func flushNow() {
    saveIndexDirty = false
    saveFlushScheduled = false
    let data = try? NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: true)
    try? data?.write(to: indexURL, options: [.atomic])
    recordSaveWrite()
  }

  /// P1：saveWriteCount 自增（saveWriteLock 守护，saveQueue 与主线程 flushNow 均调）。
  private func recordSaveWrite() {
    saveWriteLock.lock()
    saveWriteCount += 1
    saveWriteLock.unlock()
  }

  /// Persist the current items to the index plist (main-thread call).
  /// P1：保留为 `flushNow` 别名（向后兼容外部调用点，如未迁移的测试夹具）。
  func saveIndex() {
    flushNow()
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
    // P1：合并写（0.1s 窗口），替换原 saveIndex()。probe 并发 4 路批量回填 → 大量合并机会。
    scheduleSaveIndex()
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
