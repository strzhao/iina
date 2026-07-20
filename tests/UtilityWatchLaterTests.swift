//
//  UtilityWatchLaterTests.swift
//  iinaTests
//
//  蓝队自写单元测试（编译期健康自检）— 修复 B / C3 契约：
//  Utility.playbackProgressFromWatchLater 逐行扫描 watch-later 文件，跳过 # 注释行，
//  取首个 start= 行解析；非 Double/空/仅注释/redirect 返回 nil；向后兼容既有结果。
//
//  注意：Utility.watchLaterURL 是 lazy 静态 URL，指向真实 app support 目录。
//  测试通过写入 watchLaterURL/<md5> 临时文件、teardown 删除来隔离。
//

import XCTest
@testable import IINA

final class UtilityWatchLaterTests: XCTestCase {

  /// 生成一个唯一 URL 并计算其 mpvMd5，返回 (url, md5, watchLaterFile)。
  private func makeFixture() -> (url: URL, md5: String, file: URL) {
    let url = URL(fileURLWithPath: "/tmp/iina_watchlater_test_\(UUID().uuidString).mkv")
    let md5 = Utility.mpvWatchLaterMd5(url, false)
    let file = Utility.watchLaterURL.appendingPathComponent(md5)
    return (url, md5, file)
  }

  /// 写字符串到指定路径（覆盖）。
  private func write(_ content: String, to file: URL) throws {
    try content.write(to: file, atomically: true, encoding: .utf8)
  }

  /// 测试夹具清理：删除 watch-later 临时文件。
  private func cleanup(_ files: [URL]) {
    for f in files {
      try? FileManager.default.removeItem(at: f)
    }
  }

  /// 谓词 C3.1：首行即 start= 的既有行为保持不变（向后兼容）。
  func test_first_line_start_equals_backward_compatible() throws {
    let (_, _, file) = makeFixture()
    try write("start=1234.5\n", to: file)
    defer { cleanup([file]) }

    let progress = Utility.playbackProgressFromWatchLater(file.lastPathComponent)
    XCTAssertNotNil(progress)
    XCTAssertEqual(progress?.second ?? -1, 1234.5, accuracy: 0.001)
  }

  /// 谓词 C3.2：watch-later 文件首行是 # 注释，第二行才是 start= —— 必须跳过 # 行解析到 start=。
  /// 这是怪奇物语 S03E01 场景：mpv 写 watch-later 时首行常常是注释。
  func test_skips_comment_lines_to_first_start() throws {
    let (_, _, file) = makeFixture()
    try write("# redirect by mpv 0.38.0\n# another comment\nstart=987.25\n", to: file)
    defer { cleanup([file]) }

    let progress = Utility.playbackProgressFromWatchLater(file.lastPathComponent)
    XCTAssertNotNil(progress, "必须跳过 # 注释行找到首个 start= 行")
    XCTAssertEqual(progress?.second ?? -1, 987.25, accuracy: 0.001)
  }

  /// 谓词 C3.3：start= 值非数字时返回 nil（不崩溃）。
  func test_non_numeric_start_returns_nil() throws {
    let (_, _, file) = makeFixture()
    try write("# comment\nstart=NOPTS\n", to: file)
    defer { cleanup([file]) }

    let progress = Utility.playbackProgressFromWatchLater(file.lastPathComponent)
    XCTAssertNil(progress, "start= 非数字必须返回 nil")
  }

  /// 谓词 C3.4：文件只有 redirect/空内容时返回 nil。
  func test_only_redirect_lines_returns_nil() throws {
    let (_, _, file) = makeFixture()
    try write("# redirect by mpv\n# open.URL.hash\n", to: file)
    defer { cleanup([file]) }

    let progress = Utility.playbackProgressFromWatchLater(file.lastPathComponent)
    XCTAssertNil(progress, "仅含注释/redirect 必须返回 nil")
  }

  /// 谓词 C3.5：文件不存在时返回 nil（既有行为）。
  func test_missing_file_returns_nil() {
    let nonexistentMd5 = "nonexistent_\(UUID().uuidString)_md5"
    let progress = Utility.playbackProgressFromWatchLater(nonexistentMd5)
    XCTAssertNil(progress, "文件不存在必须返回 nil")
  }

  /// 谓词 C3.6：空文件返回 nil。
  func test_empty_file_returns_nil() throws {
    let (_, _, file) = makeFixture()
    try write("", to: file)
    defer { cleanup([file]) }

    let progress = Utility.playbackProgressFromWatchLater(file.lastPathComponent)
    XCTAssertNil(progress, "空文件必须返回 nil")
  }

  /// 谓词 C3.7：start= 出现在注释行之前 —— 第一个 start= 被解析（即使前面还有更多 start= 行也只取首个）。
  func test_takes_first_start_line() throws {
    let (_, _, file) = makeFixture()
    try write("start=100\nstart=200\n", to: file)
    defer { cleanup([file]) }

    let progress = Utility.playbackProgressFromWatchLater(file.lastPathComponent)
    XCTAssertEqual(progress?.second ?? -1, 100, accuracy: 0.001,
                   "必须取首个 start= 行（100 而非 200）")
  }
}
