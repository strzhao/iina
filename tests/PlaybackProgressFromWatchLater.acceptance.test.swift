//
//  PlaybackProgressFromWatchLater.acceptance.test.swift
//  iina
//
//  红队验收测试 — Utility.playbackProgressFromWatchLater 格式兼容（黑盒视角，基于契约 C3）
//
//  本测试针对修复 B：`playbackProgressFromWatchLater` 逐行扫描，跳过 `#` 注释行，
//  取首个 `start=` 行。非 Double 返回 nil。
//
//  修后契约（测试权威源，state.md ## 契约规约 C3）：
//    playbackProgressFromWatchLater(_ mpvMd5: String) -> VideoTime?
//      - 逐行扫描 watch-later 文件
//      - 跳过 `hasPrefix("#")` 注释行（含 mpv 0.38.0 `# redirect entry` 与 `# filename`）
//      - 取首个 `hasPrefix("start=")` 行解析
//      - `start=` 值非 Double 返回 nil
//      - 文件不存在/空/仅注释无 start=/redirect 文件 → nil
//      - 向后兼容：现有"首行 start=" 文件行为不变（返回 VideoTime(start)）
//
//  覆盖验收场景 P3（每条 det-machine 硬断言，失败必挂）：
//    P3-a: 首行 "# filename=..." + 次行 "start=42.5" → 42.5
//    P3-b: 文件含 "# redirect entry" → nil
//    P3-c: 空文件 → nil
//    P3-d: 仅注释（多行 # 无 start=）→ nil
//    P3-e: "start=abc"（非数字）→ nil
//    P3-f: 向后兼容 — 首行 "start=12.5" → 12.5（不变）
//

import XCTest
@testable import IINA

final class PlaybackProgressFromWatchLaterAcceptanceTests: XCTestCase {

  // MARK: - 测试夹具：临时 watch-later 文件

  /// 用唯一的 md5 key 在 Utility.watchLaterURL 目录下创建临时 watch-later 文件。
  /// 返回 md5（供 `playbackProgressFromWatchLater` 读取）与文件绝对路径（供 tearDown 清理）。
  /// 使用真 Utility.watchLaterURL 目录而非 mock，保证读取路径与生产一致（黑盒视角）。
  private func writeWatchLaterFixture(md5Suffix: String, content: String) -> (md5: String, path: String) {
    let md5 = "iina_redteam_test_\(md5Suffix)_\(UUID().uuidString)"
    let dir = Utility.watchLaterURL
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(md5).path
    try? FileManager.default.removeItem(atPath: path)  // 防前次残留
    XCTAssertNoThrow(
      try content.write(toFile: path, atomically: true, encoding: .utf8),
      "夹具写入失败：\(path)（md5=\(md5)）")
    return (md5, path)
  }

  private var cleanupPaths: [String] = []

  override func tearDown() {
    for path in cleanupPaths {
      try? FileManager.default.removeItem(atPath: path)
    }
    cleanupPaths.removeAll()
    super.tearDown()
  }

  // MARK: - P3-a [det-machine] 首行 # 注释 + 次行 start= → 解析次行

  /// 谓词: P3「首行"# filename" + 次行"start=42.5" → 42.5」
  ///
  /// 这是修复 B 的核心断言：防御 mpv 开启 `write_filename_in_watch_later_config`
  /// （首行变 `# filename=...`）或读到父目录 redirect（`# redirect entry`）。
  ///
  /// Mutation-Survival: 若实现仍只读 `firstLine`，此测试必挂（firstLine 不以 "start=" 开头 → nil）。
  func test_P3a_firstLineComment_secondLineStart_returnsValue() {
    let content = "# filename=/nas/video.mkv\nstart=42.5\n# hash=abc\n"
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3a_comment_then_start", content: content)
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertNotNil(result, "P3a 失败：首行注释+次行 start=42.5 必须解析出 VideoTime。"
                             + "若为 nil 说明实现仍只读 firstLine（修复 B 未生效）。")
    XCTAssertEqual(result?.second ?? -1, 42.5, accuracy: 0.001,
                   "P3a 失败：解析值必须为 42.5（次行 start=），实际: \(String(describing: result?.second))")
  }

  // MARK: - P3-b [det-machine] 父目录 redirect 文件 → nil

  /// 谓词: P3「`# redirect entry` 文件 → nil」
  ///
  /// mpv 0.38.0 `write_redirects_for_parent_dirs` 会为每个父目录写 redirect 文件。
  /// 这些文件不是进度文件，读到不能误报 0 或崩溃，必须返回 nil。
  ///
  /// Mutation-Survival: 若实现把 "首行无 start= 即返回 nil" 改成 "任意非空文件返回 0"，
  /// 此测试必挂（拿到 0 而非 nil）。
  func test_P3b_redirectEntryFile_returnsNil() {
    let content = "# redirect entry\n"
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3b_redirect", content: content)
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertNil(result,
                 "P3b 失败：父目录 redirect 文件（`# redirect entry`）必须返回 nil。"
                 + "实际: \(String(describing: result))")
  }

  // MARK: - P3-c [det-machine] 空文件 → nil

  /// 谓词: P3「空文件 → nil」
  func test_P3c_emptyFile_returnsNil() {
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3c_empty", content: "")
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertNil(result, "P3c 失败：空文件必须返回 nil。实际: \(String(describing: result))")
  }

  // MARK: - P3-d [det-machine] 仅注释（多行 #，无 start=）→ nil

  /// 谓词: P3「仅注释无 start= 的文件 → nil」
  ///
  /// 多行注释都无 start=，逐行扫描也应返回 nil（不崩、不误报）。
  func test_P3d_onlyComments_returnsNil() {
    let content = "# header line 1\n# header line 2\n# another comment\n"
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3d_only_comments", content: content)
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertNil(result,
                 "P3d 失败：仅注释无 start= 的文件必须返回 nil。实际: \(String(describing: result))")
  }

  // MARK: - P3-e [det-machine] start=非数字 → nil

  /// 谓词: P3「`start=abc`（非 Double）→ nil」
  ///
  /// 逐行扫描到首个 start= 但值不是 Double，必须返回 nil（不崩）。
  ///
  /// Mutation-Survival: 若实现 try? Double 失败 fallback 成 0，此测试必挂（拿到 0 而非 nil）。
  func test_P3e_nonNumericStart_returnsNil() {
    let content = "start=abc\n"
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3e_non_numeric", content: content)
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertNil(result,
                 "P3e 失败：start=abc（非数字）必须返回 nil。实际: \(String(describing: result))")
  }

  // MARK: - P3-f [det-machine] 向后兼容：首行 start= → 返回值（不变）

  /// 谓词: P3「首行 "start=12.5" → 12.5（不变）」
  ///
  /// CONTRACT_AMBIGUOUS: 契约 C3 说"向后兼容首行 start="，即现有 22 个进度文件解析结果不变。
  /// 此测试验证这点：逐行扫描实现读到首行 start= 即返回，行为等价旧实现。
  ///
  /// Mutation-Survival: 若实现误把"首行即 start="改成"必须跳过若干行才读 start="，此测试必挂。
  func test_P3f_backCompat_firstLineStart_returnsValue() {
    let content = "start=12.5\n"
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3f_back_compat", content: content)
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertNotNil(result,
                   "P3f 失败：首行 start=12.5 必须向后兼容返回 VideoTime（解析结果不变）。"
                   + "实际: \(String(describing: result))")
    XCTAssertEqual(result?.second ?? -1, 12.5, accuracy: 0.001,
                   "P3f 失败：解析值必须为 12.5，实际: \(String(describing: result?.second))")
  }

  // MARK: - P3-g [det-machine] 不存在文件 → nil（契约隐含）

  /// 谓词: 不存在的 md5（无对应文件） → nil
  ///
  /// 旧实现 `StreamReader(path:)` 初始化失败即 nil。修复 B 不应改变这点。
  func test_P3g_nonExistentFile_returnsNil() {
    let nonExistentMd5 = "iina_redteam_never_exists_\(UUID().uuidString)"

    let result = Utility.playbackProgressFromWatchLater(nonExistentMd5)

    XCTAssertNil(result,
                 "P3g 失败：不存在的文件必须返回 nil。实际: \(String(describing: result))")
  }

  // MARK: - P3-h [det-machine] 强化：多 start= 行取首个

  /// 谓词: P3 强化 — 多 start= 行（首个注释、次个 start=100、三个 start=200）→ 取首个 start=（100）
  ///
  /// 防止实现取"最后一个 start=" 或"任意 start="。
  func test_P3h_multipleStartLines_takesFirst() {
    let content = "# comment\nstart=100\nstart=200\n"
    let (md5, path) = writeWatchLaterFixture(md5Suffix: "P3h_multi_start", content: content)
    cleanupPaths.append(path)

    let result = Utility.playbackProgressFromWatchLater(md5)

    XCTAssertEqual(result?.second ?? -1, 100.0, accuracy: 0.001,
                   "P3h 失败：多 start= 行必须取首个 start=（100）。"
                   + "实际: \(String(describing: result?.second))")
  }
}
