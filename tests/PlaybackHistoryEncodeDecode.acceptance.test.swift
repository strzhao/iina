//
//  PlaybackHistoryEncodeDecode.acceptance.test.swift
//  iina
//
//  红队验收测试 — PlaybackHistory mpvProgress 持久化 encode/decode 往返（黑盒视角，契约 A1/C1）
//
//  本测试针对修复 A1：`PlaybackHistory` 新增 `KeyMpvProgress`，encode 持久化 mpvProgress，
//  init?(coder:) 优先 decode 持久化值，缺失时 fallback playbackProgressFromWatchLater。
//
//  修后契约（测试权威源，state.md ## 契约规约 C1 / 修复 A1）：
//    PlaybackHistory: NSObject, NSSecureCoding
//      - 新增 KeyMpvProgress 常量
//      - encode(with:) 持久化 mpvProgress 字段
//      - init?(coder:) 优先 decode KeyMpvProgress 持久化值
//      - 缺失时 fallback Utility.playbackProgressFromWatchLater(mpvMd5)（向后兼容旧 plist）
//
//  覆盖验收场景 P5（det-machine，NSKeyedArchiver 真实 round-trip）：
//    P5-a: encode(mpvProgress=X) → NSKeyedArchiver 归档 → init(coder:) → 取回 X
//    P5-b: 无 mpvProgress（旧 plist 兼容）→ init(coder:) 回到 fallback 路径
//    P5-c: 不同 X 值（0/大数/小数）往返不漂移
//

import XCTest
@testable import IINA

final class PlaybackHistoryEncodeDecodeAcceptanceTests: XCTestCase {

  // MARK: - 辅助：构造一条 PlaybackHistory（用现有 designated init，然后改 mpvProgress）

  /// 用现有公开 designated init 构造，再通过 var mpvProgress 赋值（既有行为，非蓝队新增 API）。
  /// CONTRACT_AMBIGUOUS: 契约 A1 说"init?(coder:) 优先 decode 持久化值"，
  ///   但没说 designated init 的签名变化。测试假设既有 `init(url:duration:name:title:mpvMd5:)`
  ///   仍可用（非新签名），且 mpvProgress 仍是 var（setter 可访问）。
  ///   若实现改了 init 签名或 mpvProgress 变 let，测试在夹具层失败并暴露 seam 缺失，符合红队预期。
  private func makeHistoryEntry(mpvProgressSeconds: Double?,
                                 urlPath: String = "/tmp/iina_redteam_encode_\(UUID().uuidString).mkv",
                                 duration: Double = 1000.0,
                                 mpvMd5: String = "iina_redteam_md5_\(UUID().uuidString)") -> PlaybackHistory {
    let entry = PlaybackHistory(
      url: URL(fileURLWithPath: urlPath),
      duration: duration,
      name: urlPath as String,
      title: nil,
      mpvMd5: mpvMd5
    )
    entry.mpvProgress = mpvProgressSeconds.map { VideoTime($0) }
    return entry
  }

  /// 真实 NSKeyedArchiver round-trip（P5 硬证据）。
  /// 注：PlaybackHistory 的 NSSecureCoding unarchiver 须在 allowedClasses 含 PlaybackHistory.self
  /// （既有 HistoryController.read 用法）。VideoTime 若被 encode，必须支持 NSSecureCoding 或
  /// 实现内部改用 encode Double（实现细节，黑盒不假定）。
  /// CONTRACT_AMBIGUOUS: VideoTime 当前不是 NSSecureCoding（纯 class），A1 实现须处理这点
  /// （要么改 VideoTime，要么 encode Double）。测试只关心从黑盒视角 round-trip 拿回原值。
  private func roundTrip(_ entry: PlaybackHistory) -> PlaybackHistory? {
    do {
      let data = try NSKeyedArchiver.archivedData(
        withRootObject: entry, requiringSecureCoding: true)
      let unarchived = try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [PlaybackHistory.self], from: data)
      return unarchived as? PlaybackHistory
    } catch {
      XCTFail("P5 夹具失败：NSKeyedArchiver round-trip 抛错: \(error)。"
              + "可能原因：A1 未把 mpvProgress 纳入 encode 或 VideoTime 不支持 NSSecureCoding。")
      return nil
    }
  }

  // MARK: - P5-a [det-machine] 往返：mpvProgress=X → 归档 → 解档 → 取回 X

  /// 谓词: P5「encode/decode 往返 — 写回 mpvProgress=X → NSKeyedArchiver 归档 → init(coder:) → 取回 X」
  ///
  /// 这是 A1 的硬证据：证明 mpvProgress 经 NSKeyedArchiver 持久化后能完整恢复（重启不丢）。
  /// 现实含义：history.plist 写盘后下次启动读取，条目进度还在。
  ///
  /// Mutation-Survival:
  ///   - 若实现忘了在 encode 里 encode mpvProgress → 解档取回 nil（测试挂）
  ///   - 若实现 init?(coder:) 不优先 decode KeyMpvProgress → 回到 watch-later fallback（取回 nil，测试挂）
  ///   - 若实现只 encode 不 decode → 取回 nil（测试挂）
  func test_P5a_mpvProgress_survivesArchiveRoundTrip() {
    let original = makeHistoryEntry(mpvProgressSeconds: 250.0)
    XCTAssertEqual(original.mpvProgress?.second ?? -1, 250.0, accuracy: 0.001,
                   "P5a 前置失败：夹具构造 mpvProgress=250 失败，实际: \(String(describing: original.mpvProgress))")

    let restored = roundTrip(original)

    XCTAssertNotNil(restored, "P5a 失败：round-trip 解档返回 nil")
    XCTAssertEqual(restored?.mpvProgress?.second ?? -1, 250.0, accuracy: 0.001,
                   "P5a 失败：mpvProgress 往返后必须为 250.0（不漂移）。"
                   + "实际: \(String(describing: restored?.mpvProgress?.second))。"
                   + "若为 -1/nil：A1 encode 或 init?(coder:) decode 缺失 KeyMpvProgress 分支。")
  }

  // MARK: - P5-b [det-machine] 无 mpvProgress（旧 plist）→ init(coder:) 不崩

  /// 谓词: P5-b「旧 plist 兼容：mpvProgress=nil → 归档 → 解档 → 不崩」
  ///
  /// 防止 A1 改动后旧条目（无 KeyMpvProgress key）解档崩溃。
  /// CONTRACT_AMBIGUOUS: init?(coder:) 应在 decode KeyMpvProgress 失败时 fallback
  ///   Utility.playbackProgressFromWatchLater(mpvMd5)。测试不依赖 watch-later 真实文件
  ///   （夹具用随机 md5 对应无 watch-later），故 fallback 结果应为 nil。
  func test_P5b_nilMpvProgress_backwardsCompat() {
    let original = makeHistoryEntry(mpvProgressSeconds: nil)
    XCTAssertNil(original.mpvProgress, "P5b 前置失败：夹具构造 mpvProgress=nil 失败")

    let restored = roundTrip(original)

    XCTAssertNotNil(restored,
                    "P5b 失败：旧 plist（无 KeyMpvProgress）round-trip 不得返回 nil/崩。"
                    + "实际: \(String(describing: restored))")
    // 无 watch-later 文件时 fallback 也返回 nil（合理，条目进入"无进度"状态）
    XCTAssertNil(restored?.mpvProgress,
                 "P5b: 无 mpvProgress + 无 watch-later → 解档 mpvProgress 应为 nil。"
                 + "实际: \(String(describing: restored?.mpvProgress))")
  }

  // MARK: - P5-c [det-machine] 多值往返不漂移（0 / 大数 / 小数）

  /// 谓词: P5-c「不同 X 值往返不漂移」
  ///
  /// 边界值覆盖：极小（0.1s）/ 中（1000s）/ 大（86400s = 1天）。
  /// 防止实现用 Int 截断或精度丢失。
  func test_P5c_multipleValues_noDrift() {
    for x in [0.1, 1.0, 1000.0, 86400.0] {
      let original = makeHistoryEntry(mpvProgressSeconds: x)
      let restored = roundTrip(original)
      XCTAssertEqual(restored?.mpvProgress?.second ?? -999, x, accuracy: 0.001,
                     "P5c 失败：mpvProgress=\(x) 往返后应仍为 \(x)。"
                     + "实际: \(String(describing: restored?.mpvProgress?.second))。"
                     + "若为 -999/nil：A1 未持久化；若为近似但不等：精度丢失（检查是否用 Int 截断）。")
    }
  }

  // MARK: - P5-d [det-machine] 其它字段仍正确持久化（回归保护）

  /// 谓词: P5-d「mpvProgress 外的字段（url/duration/mpvMd5/played）往返不丢」
  ///
  /// A1 改动 encode/init(coder:) 必须不破坏既有字段持久化。
  func test_P5d_otherFields_surviveRoundTrip() {
    let original = makeHistoryEntry(mpvProgressSeconds: 50.0,
                                     urlPath: "/tmp/iina_redteam_other_fields.mkv",
                                     duration: 2000.0,
                                     mpvMd5: "iina_redteam_md5_other")
    original.played = true

    let restored = roundTrip(original)

    XCTAssertEqual(restored?.url.path, "/tmp/iina_redteam_other_fields.mkv",
                   "P5d 失败：url 往返漂移。实际: \(String(describing: restored?.url.path))")
    XCTAssertEqual(restored?.duration.second ?? -1, 2000.0, accuracy: 0.001,
                   "P5d 失败：duration 往返漂移。实际: \(String(describing: restored?.duration.second))")
    XCTAssertEqual(restored?.mpvMd5, "iina_redteam_md5_other",
                   "P5d 失败：mpvMd5 往返漂移。实际: \(String(describing: restored?.mpvMd5))")
    XCTAssertEqual(restored?.played, true,
                   "P5d 失败：played 往返漂移。实际: \(String(describing: restored?.played))")
  }

  // MARK: - P5-e [det-machine] 既有 plist 解码兼容（数组根）

  /// 谓词: P5-e「既有 HistoryController.save 用 NSArray 根归档也能解档」
  ///
  /// 生产用 `NSKeyedArchiver.archivedData(withRootObject: history [数组])`。
  /// 测试模拟这个真实路径（不是单对象根）。
  func test_P5e_arrayRoot_roundTrip() {
    let entry1 = makeHistoryEntry(mpvProgressSeconds: 10.0, mpvMd5: "arr_md5_1")
    let entry2 = makeHistoryEntry(mpvProgressSeconds: 20.0, mpvMd5: "arr_md5_2")
    let originalArray: [PlaybackHistory] = [entry1, entry2]

    do {
      let data = try NSKeyedArchiver.archivedData(
        withRootObject: originalArray, requiringSecureCoding: true)
      let unarchived = try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSArray.self, PlaybackHistory.self], from: data)
      guard let restored = unarchived as? [PlaybackHistory] else {
        XCTFail("P5e 失败：NSArray 根解档类型转换失败")
        return
      }
      XCTAssertEqual(restored.count, 2, "P5e 失败：数组大小漂移")
      XCTAssertEqual(restored[0].mpvProgress?.second ?? -1, 10.0, accuracy: 0.001,
                     "P5e 失败：数组根 [0].mpvProgress 漂移")
      XCTAssertEqual(restored[1].mpvProgress?.second ?? -1, 20.0, accuracy: 0.001,
                     "P5e 失败：数组根 [1].mpvProgress 漂移")
    } catch {
      XCTFail("P5e 失败：NSArray 根 round-trip 抛错: \(error)")
    }
  }
}
