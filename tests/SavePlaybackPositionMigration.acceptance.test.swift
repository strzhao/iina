//
//  SavePlaybackPositionMigration.acceptance.test.swift
//  iina
//
//  红队验收测试 — savePlaybackPosition 写回 mpvProgress + add 覆盖迁移（黑盒视角，契约 A2/A3/C1）
//
//  本测试针对修复 A2（savePlaybackPosition 独立回写）+ A3（add 覆盖迁移 mpvProgress）。
//
//  修后契约（测试权威源，state.md ## 契约规约 C1）：
//    A2: PlayerCore.savePlaybackPosition 把 mpvProgress 回写提到 savePositionOnQuit guard 之前；
//        info.state.active && info.videoPosition != nil 时调 HistoryController.updateProgress。
//    A3: HistoryController.add remove 旧条目前必须迁移其 mpvProgress 到新条目
//        （init 接受 mpvProgress 参数或 remove 前取旧值传入），禁止被 init 默认 nil 覆盖。
//    updateProgress 复用 add 既有 queue.async + $history.withLock 调度；
//    为 P2 同步断言暴露 waitForDrain() 测试 seam。
//
//  CONTRACT_AMBIGUOUS:
//    1) A2 说 savePlaybackPosition 调 HistoryController.updateProgress。
//       测试不直接调 PlayerCore.savePlaybackPosition（依赖完整 mpv/info 环境，超 acceptance 范围），
//       而是黑盒测 HistoryController.updateProgress 的对外契约。
//    2) A3 说 "init 接受 mpvProgress 参数或 remove 前取旧值传入"。测试不关心实现细节，
//       只关心黑盒行为：两次 add 同 url + 中间 updateProgress 后，第二次 add 后 mpvProgress 不丢。
//    3) waitForDrain() 是测试 seam，签名假设 `func waitForDrain()` 无参无返回。
//       若实现改名（如 flushQueue/drain），测试在夹具层失败，暴露 seam 缺失，符合红队预期。
//
//  覆盖验收场景（det-machine 硬断言）：
//    P2: updateProgress 后 entry.mpvProgress.second == 传入值
//    P6: 两次 add 同 url + 中间 updateProgress，第二次 add 后 entry.mpvProgress 不丢
//

import XCTest
@testable import IINA

final class SavePlaybackPositionMigrationAcceptanceTests: XCTestCase {

  // MARK: - 清理

  private let redTeamPrefix = "/tmp/iina_redteam_spbp_"

  private func cleanupInjectedHistory() {
    HistoryController.shared.history.removeAll {
      $0.url.path.hasPrefix("/tmp/iina_redteam_spbp_")
    }
  }

  override func tearDown() {
    cleanupInjectedHistory()
    super.tearDown()
  }

  // MARK: - 辅助：唯一 url + duration

  private func uniqueUrl() -> URL {
    URL(fileURLWithPath: "\(redTeamPrefix)\(UUID().uuidString).mkv")
  }

  // MARK: - P2 [det-machine] updateProgress 写回 mpvProgress

  /// 谓词: P2「HistoryController.updateProgress(url:progress:) 后，对应 entry.mpvProgress.second == 传入 progress」
  ///
  /// 契约 A2：savePlaybackPosition 在 savePositionOnQuit guard 前调 updateProgress。
  /// 此测试不调 PlayerCore（黑盒边界），直接测 updateProgress 的黑盒契约。
  ///
  /// Mutation-Survival:
  ///   - 若实现忘了 updateProgress 实现 → 方法不存在/默认行为 → 测试挂
  ///   - 若 updateProgress 用错 key 或不写 mpvProgress → 取回 nil → 测试挂
  func test_P2_updateProgress_writesMpvProgress() {
    let url = uniqueUrl()
    let md5 = Utility.mpvWatchLaterMd5(url, false)

    // 先 add 一条无 mpvProgress 的条目（模拟首次播放）
    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()  // 同步等队列排空（C1 seam）

    // 验证 add 后 mpvProgress 为 nil（init 默认）
    let entryBeforeUpdate = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertNotNil(entryBeforeUpdate, "P2 前置失败：add 后应有对应条目")
    XCTAssertNil(entryBeforeUpdate?.mpvProgress,
                 "P2 前置失败：add 后 mpvProgress 应为 nil（init 默认，待 updateProgress 写入）")

    // 调用 updateProgress 写回 progress=250
    HistoryController.shared.updateProgress(url: url, progress: VideoTime(250.0))
    HistoryController.shared.waitForDrain()

    let entryAfterUpdate = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertNotNil(entryAfterUpdate, "P2 失败：updateProgress 后条目消失")
    XCTAssertEqual(entryAfterUpdate?.mpvProgress?.second ?? -1, 250.0, accuracy: 0.001,
                   "P2 失败：updateProgress(progress=250) 后 entry.mpvProgress.second 必须为 250。"
                   + "实际: \(String(describing: entryAfterUpdate?.mpvProgress?.second))。"
                   + "若为 -1/nil：updateProgress 未写回 mpvProgress 字段（A2 契约违反）。")
  }

  // MARK: - P2-b [det-machine] updateProgress 多次调用不丢

  /// 谓词: P2-b「updateProgress 多次调用，最新值生效」
  func test_P2b_updateProgress_multipleCalls_latestValue() {
    let url = uniqueUrl()
    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()

    HistoryController.shared.updateProgress(url: url, progress: VideoTime(100.0))
    HistoryController.shared.updateProgress(url: url, progress: VideoTime(200.0))
    HistoryController.shared.updateProgress(url: url, progress: VideoTime(300.0))
    HistoryController.shared.waitForDrain()

    let md5 = Utility.mpvWatchLaterMd5(url, false)
    let entry = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertEqual(entry?.mpvProgress?.second ?? -1, 300.0, accuracy: 0.001,
                   "P2b 失败：多次 updateProgress 后应保留最新值 300。"
                   + "实际: \(String(describing: entry?.mpvProgress?.second))")
  }

  // MARK: - P6 [det-machine] add 覆盖迁移：两次 add 同 url + 中间 updateProgress → 第二次后不丢

  /// 谓词: P6「连续两次 add 同一 url（模拟重复 fileLoaded），第二次 add 后 entry.mpvProgress
  ///        仍是首次写回值（不被 init 默认 nil 覆盖）」
  ///
  /// 这是 A3 的核心断言：重复播放同文件时，add 会 remove 旧条目 + insert 新条目（init 不设 mpvProgress）。
  /// 若 A3 未实现迁移，新条目 mpvProgress=nil → bug 重现。
  ///
  /// 步骤：
  ///   1. add(url) → 条目 A（mpvProgress=nil）
  ///   2. updateProgress(url, 250) → A.mpvProgress=250
  ///   3. add(url) 再调一次 → 应 remove A、insert 新条目 B，且 B.mpvProgress==250（迁移）
  ///
  /// Mutation-Survival:
  ///   - 若 A3 未实现 → B.mpvProgress=nil → 测试挂
  ///   - 若 A3 实现错位（先 remove 再取旧值）→ 取不到旧值 → B.mpvProgress=nil → 测试挂
  ///   - 若 A3 用 url 匹配但 url 漂移 → 也取不到 → 测试挂
  func test_P6_addTwSameUrl_migratesMpvProgress() {
    let url = uniqueUrl()
    let md5 = Utility.mpvWatchLaterMd5(url, false)

    // 步骤 1：首次 add
    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()

    // 步骤 2：updateProgress 写回 mpvProgress=250
    HistoryController.shared.updateProgress(url: url, progress: VideoTime(250.0))
    HistoryController.shared.waitForDrain()

    // 验证步骤 2 后 mpvProgress=250
    let entryAfterUpdate = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertEqual(entryAfterUpdate?.mpvProgress?.second ?? -1, 250.0, accuracy: 0.001,
                   "P6 前置失败：updateProgress 后 mpvProgress 应为 250。"
                   + "实际: \(String(describing: entryAfterUpdate?.mpvProgress?.second))")

    // 步骤 3：第二次 add（模拟重新打开同一文件，触发 fileLoaded → add）
    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()

    // 验证步骤 3 后 mpvProgress 仍是 250（A3 迁移生效）
    let entryAfterSecondAdd = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertNotNil(entryAfterSecondAdd,
                    "P6 失败：第二次 add 后找不到对应条目（md5=\(md5)）")
    XCTAssertEqual(entryAfterSecondAdd?.mpvProgress?.second ?? -1, 250.0, accuracy: 0.001,
                   "P6 失败：第二次 add 后 entry.mpvProgress 必须迁移保留为 250（不被 nil 覆盖）。"
                   + "实际: \(String(describing: entryAfterSecondAdd?.mpvProgress?.second))。"
                   + "若为 -1/nil：A3 迁移未实现（修复未生效，bug 重现）。")
  }

  // MARK: - P6-b [det-machine] add 迁移：迁移 updateProgress 后的值，不是更早的

  /// 谓词: P6-b「add 迁移时取的是最新 updateProgress 值，不是首次 add 时的值」
  ///
  /// 步骤：
  ///   1. add(url) → A（mpvProgress=nil）
  ///   2. updateProgress(url, 100) → A.mpvProgress=100
  ///   3. updateProgress(url, 500) → A.mpvProgress=500（覆盖）
  ///   4. add(url) → B.mpvProgress==500（不是 100）
  ///
  /// 防止实现缓存"首次 add 时的 mpvProgress"用作迁移源。
  func test_P6b_addMigrates_latestUpdateProgressValue() {
    let url = uniqueUrl()
    let md5 = Utility.mpvWatchLaterMd5(url, false)

    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()
    HistoryController.shared.updateProgress(url: url, progress: VideoTime(100.0))
    HistoryController.shared.waitForDrain()
    HistoryController.shared.updateProgress(url: url, progress: VideoTime(500.0))
    HistoryController.shared.waitForDrain()

    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()

    let entry = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertEqual(entry?.mpvProgress?.second ?? -1, 500.0, accuracy: 0.001,
                   "P6b 失败：第二次 add 应迁移最新 updateProgress 值 500，不是首次的 100。"
                   + "实际: \(String(describing: entry?.mpvProgress?.second))")
  }

  // MARK: - P6-c [det-machine] add 新 url（无历史）→ mpvProgress=nil（不误填）

  /// 谓词: P6-c「add 一个新 url（无历史 mpvProgress）→ 条目 mpvProgress=nil」
  ///
  /// 防止 A3 迁移逻辑误把 nil→非 nil 转换（如用 0 兜底）。
  func test_P6c_addNewUrl_mpvProgressNil() {
    let url = uniqueUrl()
    let md5 = Utility.mpvWatchLaterMd5(url, false)

    HistoryController.shared.add(url, duration: 1000.0, title: nil, false)
    HistoryController.shared.waitForDrain()

    let entry = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertNotNil(entry, "P6c 前置失败：新 add 应有条目")
    XCTAssertNil(entry?.mpvProgress,
                 "P6c 失败：新 url 首次 add 后 mpvProgress 必须为 nil（无 updateProgress 调用）。"
                 + "实际: \(String(describing: entry?.mpvProgress))。"
                 + "若非 nil：A3 迁移逻辑可能误把缺失值当 0 或其它默认值。")
  }

  // MARK: - P6-d [det-machine] updateProgress 不存在的 url → 不崩（防御）

  /// 谓词: P6-d「updateProgress 一个不存在的 url（无 history 条目）→ 不崩」
  ///
  /// 防御性：savePlaybackPosition 可能在 history 条目被删后仍被调用。
  /// CONTRACT_AMBIGUOUS: updateProgress 对不存在 url 的行为契约未明确。
  ///   合理选择：静默 no-op（不崩、不创建新条目）。
  func test_P6d_updateProgress_nonExistentUrl_doesNotCrash() {
    let nonExistentUrl = uniqueUrl()

    // 调用不得崩
    HistoryController.shared.updateProgress(url: nonExistentUrl, progress: VideoTime(100.0))
    HistoryController.shared.waitForDrain()

    // 验证：不应为不存在的 url 创建新条目（合理行为）
    let md5 = Utility.mpvWatchLaterMd5(nonExistentUrl, false)
    let entry = HistoryController.shared.history.first { $0.mpvMd5 == md5 }
    XCTAssertNil(entry,
                 "P6d: updateProgress 对不存在的 url 不应创建新条目（合理 no-op）。"
                 + "若创建则说明 updateProgress 行为偏离契约。")
    // 到达此行即代表未崩
    XCTAssertTrue(true, "P6d: updateProgress 不存在 url 未崩（通过）")
  }
}
