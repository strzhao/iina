//
//  ContinueWatchingFallback.acceptance.test.swift
//  iina
//
//  红队验收测试 — MediaLibraryStore fallback（mpvProgress 兜底，黑盒视角，契约 C2/A4）
//
//  本测试针对修复 A4 + C2：watch-later 缺失时，progress(for:) / continueWatchingItems()
//  fallback 到 entry.mpvProgress?.second。
//
//  修后契约（测试权威源，state.md ## 契约规约 C2）：
//    MediaLibraryStore.progress(for:) / continueWatchingItems() 读取顺序：
//      ① Utility.playbackProgressFromWatchLater(mpvMd5) 实时读
//      ② nil 时 fallback entry.mpvProgress?.second（C1 持久化的独立值）
//    约束：fallback 值仍须过 watchedThreshold(0.95) 与 progress > 0 判据。
//
//  覆盖验收场景（det-machine 硬断言）：
//    P1: watch-later 缺失 + entry.mpvProgress 存在 → continueWatchingItems() 仍含该条目
//    P4: fallback 过阈值：≥0.95×duration 排除 / ==0 排除 / 0<p<0.95d 保留
//    P7: 一致性 — continueWatchingItems 集合 == {有可用进度（watch-later 或 mpvProgress）且 0<p<0.95d}
//

import XCTest
@testable import IINA

final class ContinueWatchingFallbackAcceptanceTests: XCTestCase {

  // MARK: - 常量

  /// 契约 example 用 1000s 便于百分比换算。
  private let durationSeconds: Double = 1000.0

  // MARK: - 清理

  private let redTeamPrefix = "/tmp/iina_redteam_cwfb_"

  private func cleanupInjectedHistory() {
    // history 是 @Atomic 值类型数组，须 $history.withLock 才能写回
    HistoryController.shared.$history.withLock { history in
      history.removeAll { $0.url.path.hasPrefix("/tmp/iina_redteam_cwfb_") }
    }
  }

  override func tearDown() {
    cleanupInjectedHistory()
    super.tearDown()
  }

  // MARK: - 辅助：构造 MediaItem

  private func makeMediaItem(urlPath: String) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: urlPath),
      cleanedName: URL(fileURLWithPath: urlPath).lastPathComponent,
      rawName: URL(fileURLWithPath: urlPath).lastPathComponent + ".1080p",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: durationSeconds,
      thumbnailPath: nil
    )
  }

  // MARK: - 辅助：注入 history 条目（mpvProgress 来自持久化字段，不靠 watch-later）

  /// 构造 PlaybackHistory 注入到 HistoryController.shared.history。
  ///
  /// CONTRACT_AMBIGUOUS: 契约 C2 的 fallback 路径是 entry.mpvProgress?.second。
  ///   测试通过 var mpvProgress 直接赋值（既有 setter），不依赖 watch-later 文件。
  ///   关键：mpvMd5 必须是随机字符串，保证 Utility.playbackProgressFromWatchLater
  ///   返回 nil（无对应 watch-later 文件），从而触发 fallback 路径。
  private func injectHistoryEntry(url: URL,
                                  mpvProgressSeconds: Double?,
                                  played: Bool = false,
                                  addedDate: Date = Date()) {
    // 夹具修复：mpvMd5 必须与 MediaItem 匹配（Utility.mpvWatchLaterMd5(url, ignorePath)），
    // 否则 continueWatchingItems 的 entry↔item match 失败，走不到 fallback 路径。
    // ignorePath=false 与 store.currentIgnorePath() 测试环境一致（蓝队单测已验证）。
    let mpvMd5 = Utility.mpvWatchLaterMd5(url, false)
    // 删除该 md5 对应 watch-later 文件，确保 playbackProgressFromWatchLater 返回 nil → 触发 fallback
    let watchLaterFile = Utility.watchLaterURL.appendingPathComponent(mpvMd5)
    try? FileManager.default.removeItem(at: watchLaterFile)
    let entry = PlaybackHistory(
      url: url,
      duration: durationSeconds,
      name: url.lastPathComponent,
      title: nil,
      mpvMd5: mpvMd5
    )
    entry.played = played
    entry.addedDate = addedDate
    entry.mpvProgress = mpvProgressSeconds.map { VideoTime($0) }
    // 夹具修复：history 是 @Atomic 值类型数组，直接 .append 不写回；须 $history.withLock
    HistoryController.shared.$history.withLock { history in history.append(entry) }
  }

  // MARK: - P1 [det-machine] 核心：watch-later 缺失 + mpvProgress 存在 → 仍进入 continueWatchingItems

  /// 谓词: P1「watch-later 文件缺失时，continueWatchingItems() 仍包含有 entry.mpvProgress 的条目」
  ///
  /// 这是本次修复的核心断言：用户报告 bug「点 S03E01 后入口消失」就是 watch-later 缺失 +
  /// 旧实现无 fallback 导致。修后 entry.mpvProgress 兜底，条目必须仍在结果集。
  ///
  /// 构造：history 条目（mpvProgress=100s, duration=1000s）+ 无 watch-later 文件
  /// （mpvMd5 随机，Utility.playbackProgressFromWatchLater 必返回 nil）
  ///
  /// Mutation-Survival:
  ///   - 若实现未加 fallback（旧代码），watch-later=nil → continue 跳过 → 测试挂
  ///   - 若实现 fallback 但读错字段（entry.url 而非 entry.mpvProgress）→ 取回 nil → 测试挂
  func test_P1_watchLaterMissing_mpvProgressPresent_stillInContinueWatching() {
    let urlPath = "\(redTeamPrefix)P1_present_\(UUID().uuidString).mkv"
    let item = makeMediaItem(urlPath: urlPath)
    injectHistoryEntry(url: item.url, mpvProgressSeconds: 100.0)  // 10% × duration

    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertTrue(cw.contains { $0.url == item.url },
                  "P1 失败：watch-later 缺失但 entry.mpvProgress=100s（duration=1000s, 10%）必须仍进入继续观看。"
                  + "实际 cw: \(cw.map { $0.cleanedName })。"
                  + "若此断言失败，说明 fallback 路径未生效（C2/A4 未实现）。")
  }

  // MARK: - P1-b [det-machine] progress(for:) 也走 fallback

  /// 谓词: P1-b「progress(for:) 在 watch-later 缺失时返回 entry.mpvProgress.second」
  ///
  /// 契约 C2 同时约束 progress(for:) 和 continueWatchingItems()，两者必须一致。
  func test_P1b_progressForItem_usesFallback() {
    let urlPath = "\(redTeamPrefix)P1b_\(UUID().uuidString).mkv"
    let item = makeMediaItem(urlPath: urlPath)
    injectHistoryEntry(url: item.url, mpvProgressSeconds: 250.0)  // 25%

    MediaLibraryStore.shared.setItemsForTesting([item])

    let progress = MediaLibraryStore.shared.progress(for: item)

    XCTAssertNotNil(progress,
                    "P1b 失败：watch-later 缺失但 mpvProgress=250s 时 progress(for:) 不得返回 nil。"
                    + "实际: \(String(describing: progress))")
    XCTAssertEqual(progress ?? -1, 250.0, accuracy: 0.001,
                   "P1b 失败：progress(for:) fallback 必须返回 250.0，实际: \(String(describing: progress))")
  }

  // MARK: - P4-a [det-machine] fallback 阈值：≥ 0.95×duration 排除

  /// 谓词: P4「mpvProgress ≥ duration×0.95 排除」
  ///
  /// fallback 值也必须过 watchedThreshold 判据，不能因为兜底就放入已看完条目。
  /// 0.95 × 1000 = 950 → 排除
  ///
  /// Mutation-Survival: 若实现 fallback 时漏掉阈值判断，此测试必挂（950s 被放入）。
  func test_P4a_fallback_atOrAboveThreshold_excluded() {
    for progress in [950.0, 999.0, 1000.0, 1500.0] {
      let urlPath = "\(redTeamPrefix)P4a_\(progress)_\(UUID().uuidString).mkv"
      let item = makeMediaItem(urlPath: urlPath)
      injectHistoryEntry(url: item.url, mpvProgressSeconds: progress)

      MediaLibraryStore.shared.setItemsForTesting([item])

      let cw = MediaLibraryStore.shared.continueWatchingItems()

      XCTAssertFalse(cw.contains { $0.url == item.url },
                     "P4a 失败：mpvProgress=\(progress)s ≥ 0.95×duration(950s) 不得进入继续观看。"
                     + "实际 cw 含该 item: \(cw.contains { $0.url == item.url })。"
                     + "若此断言失败，说明 fallback 未过 watchedThreshold 判据（契约 C2 约束违反）。")
      cleanupInjectedHistory()
    }
  }

  // MARK: - P4-b [det-machine] fallback == 0 排除

  /// 谓词: P4「mpvProgress == 0 排除」
  ///
  /// 零进度不应进入继续观看（契约 C2 约束：progress > 0）。
  func test_P4b_fallback_zeroProgress_excluded() {
    let urlPath = "\(redTeamPrefix)P4b_zero_\(UUID().uuidString).mkv"
    let item = makeMediaItem(urlPath: urlPath)
    injectHistoryEntry(url: item.url, mpvProgressSeconds: 0.0)

    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "P4b 失败：mpvProgress=0 不得进入继续观看。"
                   + "实际 cw: \(cw.map { $0.cleanedName })")
  }

  // MARK: - P4-c [det-machine] fallback 0 < p < 0.95×duration 保留

  /// 谓词: P4「0 < mpvProgress < 0.95×duration 保留」
  ///
  /// 边界值覆盖：1s（接近 0）/ 499s（接近 50%）/ 949s（接近阈值但不达）。
  /// 防止实现把"严格大于 0"改成"严格大于某下限"或"严格小于阈值"边界 off-by-one。
  func test_P4c_fallback_inRange_included() {
    for progress in [1.0, 499.0, 949.0] {
      let urlPath = "\(redTeamPrefix)P4c_\(progress)_\(UUID().uuidString).mkv"
      let item = makeMediaItem(urlPath: urlPath)
      injectHistoryEntry(url: item.url, mpvProgressSeconds: progress)

      MediaLibraryStore.shared.setItemsForTesting([item])

      let cw = MediaLibraryStore.shared.continueWatchingItems()

      XCTAssertTrue(cw.contains { $0.url == item.url },
                    "P4c 失败：mpvProgress=\(progress)s（0 < p < 950s）必须进入继续观看。"
                    + "实际 cw: \(cw.map { $0.cleanedName })")
      cleanupInjectedHistory()
    }
  }

  // MARK: - P7 [det-machine] 一致性：cw 集合 == {有可用进度且 0<p<0.95d}

  /// 谓词: P7「continueWatchingItems 集合 == {history 条目有可用进度（watch-later 或 mpvProgress）且 0<p<0.95×duration}」
  ///
  /// 真实场景模拟：构造混合条目，watch-later 全缺失（用随机 md5），mpvProgress 各种边界：
  ///   - A: mpvProgress=100（10%）→ 进
  ///   - B: mpvProgress=950（95%）→ 不进（阈值）
  ///   - C: mpvProgress=nil → 不进
  ///   - D: mpvProgress=0 → 不进
  ///   - E: mpvProgress=500（50%）→ 进
  ///
  /// 断言 cw 恰好为 {A, E}，集合等式。
  ///
  /// Mutation-Survival:
  ///   - 若实现把 fallback 删了 → A/E 也不进 → cw 为空 → 测试挂
  ///   - 若实现把阈值判据删了 → B 也进 → cw 含 B → 测试挂
  ///   - 若实现把 nil/0 判据删了 → C/D 也进 → 测试挂
  func test_P7_consistency_cwEqualsFilteredSet() {
    let urlA = "\(redTeamPrefix)P7_A_\(UUID().uuidString).mkv"
    let urlB = "\(redTeamPrefix)P7_B_\(UUID().uuidString).mkv"
    let urlC = "\(redTeamPrefix)P7_C_\(UUID().uuidString).mkv"
    let urlD = "\(redTeamPrefix)P7_D_\(UUID().uuidString).mkv"
    let urlE = "\(redTeamPrefix)P7_E_\(UUID().uuidString).mkv"

    let itemA = makeMediaItem(urlPath: urlA)
    let itemB = makeMediaItem(urlPath: urlB)
    let itemC = makeMediaItem(urlPath: urlC)
    let itemD = makeMediaItem(urlPath: urlD)
    let itemE = makeMediaItem(urlPath: urlE)

    injectHistoryEntry(url: itemA.url, mpvProgressSeconds: 100.0, addedDate: Date().addingTimeInterval(-40))
    injectHistoryEntry(url: itemB.url, mpvProgressSeconds: 950.0, addedDate: Date().addingTimeInterval(-30))
    injectHistoryEntry(url: itemC.url, mpvProgressSeconds: nil, addedDate: Date().addingTimeInterval(-20))
    injectHistoryEntry(url: itemD.url, mpvProgressSeconds: 0.0, addedDate: Date().addingTimeInterval(-10))
    injectHistoryEntry(url: itemE.url, mpvProgressSeconds: 500.0, addedDate: Date())

    MediaLibraryStore.shared.setItemsForTesting([itemA, itemB, itemC, itemD, itemE])

    let cw = MediaLibraryStore.shared.continueWatchingItems()
    let cwUrls = Set(cw.map { $0.url.path })
    let expected: Set<String> = [urlA, urlE]

    XCTAssertEqual(cwUrls, expected,
                   "P7 一致性失败：cw 集合必须 == {A(100s), E(500s)}。"
                   + "实际 cw: \(cwUrls.sorted())。"
                   + "期望: \(expected.sorted())。"
                   + "若包含 B(950s)：阈值未生效；若包含 C/D：nil/0 未排除；若不含 A/E：fallback 未实现。")
  }

  // MARK: - P7-b [det-machine] 一致性：watch-later 存在时优先于 mpvProgress

  /// 谓词: P7-b「watch-later 优先于 mpvProgress（契约 C2 优先级）」
  ///
  /// CONTRACT_AMBIGUOUS: 契约 C2 说优先级 watch-later > mpvProgress。但黑盒测试要验证这点，
  ///   需在 watch-later 目录创建一个真实文件（用 Utility.mpvWatchLaterMd5 计算 md5）。
  ///   测试构造：watch-later 写 start=999（即 99.9%，应被阈值排除），
  ///   mpvProgress=100（10%）。若优先级正确，cw 不含该条目（按 watch-later=999 排除）。
  ///
  /// Mutation-Survival: 若实现读错顺序（先 mpvProgress 再 watch-later）→ 取 100（10%）→ 进 cw → 测试挂。
  func test_P7b_watchLaterPrecedence_overMpvProgress() {
    let urlPath = "\(redTeamPrefix)P7b_\(UUID().uuidString).mkv"
    let item = makeMediaItem(urlPath: urlPath)
    let mpvMd5 = Utility.mpvWatchLaterMd5(item.url, false)

    // 在 watch-later 目录写文件，start=999（99.9%，超过阈值）
    let watchLaterFile = Utility.watchLaterURL.appendingPathComponent(mpvMd5)
    try? FileManager.default.createDirectory(
      at: Utility.watchLaterURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: watchLaterFile) }
    XCTAssertNoThrow(
      try "start=999\n".write(to: watchLaterFile, atomically: true, encoding: .utf8),
      "P7b 夹具失败：watch-later 文件写入失败")

    // 注入条目：mpvProgress=100（10%，本应进 cw）
    let entry = PlaybackHistory(
      url: item.url,
      duration: durationSeconds,
      name: item.url.lastPathComponent,
      title: nil,
      mpvMd5: mpvMd5  // 关键：用 watch-later 能匹配到的 md5
    )
    entry.mpvProgress = VideoTime(100.0)
    HistoryController.shared.history.append(entry)

    MediaLibraryStore.shared.setItemsForTesting([item])

    let cw = MediaLibraryStore.shared.continueWatchingItems()

    XCTAssertFalse(cw.contains { $0.url == item.url },
                   "P7b 失败：watch-later=999（99.9%）优先于 mpvProgress=100（10%）时，"
                   + "按 watch-later=999 应被阈值排除，不得进入 cw。"
                   + "实际 cw: \(cw.map { $0.cleanedName })。"
                   + "若此断言失败，说明实现读错顺序（先读 fallback 才读 watch-later）。")
  }

  // MARK: - P7-c [det-machine] 一致性：progress(for:) 与 continueWatchingItems() 看法一致

  /// 谓词: P7-c「同一 item 下，progress(for:) 返回的值 与 continueWatchingItems() 决策一致」
  ///
  /// 防止两个 API 用不同 fallback 策略（漂移）。
  func test_P7c_progressForItem_consistentWithContinueWatching() {
    // 进入 cw 的条目（mpvProgress=100）
    let urlIn = "\(redTeamPrefix)P7c_in_\(UUID().uuidString).mkv"
    let itemIn = makeMediaItem(urlPath: urlIn)
    injectHistoryEntry(url: itemIn.url, mpvProgressSeconds: 100.0)

    // 不进入 cw 的条目（mpvProgress=950，超阈值）
    let urlOut = "\(redTeamPrefix)P7c_out_\(UUID().uuidString).mkv"
    let itemOut = makeMediaItem(urlPath: urlOut)
    injectHistoryEntry(url: itemOut.url, mpvProgressSeconds: 950.0)

    MediaLibraryStore.shared.setItemsForTesting([itemIn, itemOut])

    let progressIn = MediaLibraryStore.shared.progress(for: itemIn)
    let progressOut = MediaLibraryStore.shared.progress(for: itemOut)
    let cw = MediaLibraryStore.shared.continueWatchingItems()
    let cwUrls = Set(cw.map { $0.url.path })

    XCTAssertEqual(progressIn ?? -1, 100.0, accuracy: 0.001,
                   "P7c: progress(for: inItem) 应为 100")
    XCTAssertEqual(progressOut ?? -1, 950.0, accuracy: 0.001,
                   "P7c: progress(for: outItem) 应为 950（即使超阈值也要返回原值，阈值只在 cw 过滤）")
    XCTAssertTrue(cwUrls.contains(urlIn),
                  "P7c: cw 应含 inItem（100 < 950）")
    XCTAssertFalse(cwUrls.contains(urlOut),
                   "P7c: cw 不应含 outItem（950 ≥ 950）")
  }
}
