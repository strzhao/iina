//
//  MediaLibraryScanner.acceptance.test.swift
//  iina
//
//  红队验收测试 — 目录扫描器（黑盒视角，基于 ## 契约规约）
//
//  覆盖验收场景：
//    场景 8-P2 [det-machine]: 目录含 .png 和 .mkv 混合 → 仅显示视频文件（∀ episode 不匹配 \.png$）
//    场景 11-P1 [det-machine]: NAS 未挂载 → 显示不可访问提示（路径不可访问抛 MediaLibraryError.pathNotAccessible）
//    场景 11-P2 [det-machine]: 不崩溃且窗口响应（扫描器抛错不 crash）
//    场景 16-P1 [det-machine]: ∀ card 扩展名 ∈ {mkv,mp4,avi,mov,m4v,ts,flv,webm}
//    场景 17-P1 [det-machine]: 分类目录为空 → cells.count==0
//  覆盖契约边界值：
//    视频扩展名白名单 ∈ {mkv, mp4, avi, mov, m4v, ts, flv, webm}
//    扫描根路径固定子目录: 电影 / 电视剧 / 其它
//    容错：根路径不可访问 → 抛 MediaLibraryError.pathNotAccessible
//

import XCTest
@testable import iina

final class MediaLibraryScannerAcceptanceTests: XCTestCase {

  /// 视频扩展名白名单（契约逐字一致）
  private let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v", "ts", "flv", "webm"]

  // MARK: - 辅助：构建临时目录结构

  /// 创建临时根目录，含 电影/电视剧/其它 三个固定子目录。
  /// 返回根目录 URL。调用方负责清理（tearDown 中删除）。
  private func makeTempRoot() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("iina_media_lib_test_\(UUID().uuidString)", isDirectory: true)
    for sub in ["电影", "电视剧", "其它"] {
      let dir = tmp.appendingPathComponent(sub, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return tmp
  }

  private func writeDummyFile(at dir: URL, name: String, content: Data = Data([0x00])) throws -> URL {
    let fileURL = dir.appendingPathComponent(name)
    try content.write(to: fileURL)
    return fileURL
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - 场景 16-P1：仅识别视频白名单扩展名

  /// 谓词: 场景16-P1 [det-machine]: ∀ card 扩展名 ∈ {mkv,mp4,avi,mov,m4v,ts,flv,webm}
  /// 实现：在 电影 目录放入白名单内各一个 + 非视频文件（.png/.txt/.jpg/.nfo），断言扫描结果仅含白名单扩展名
  func test_scan_filters_non_video_extensions() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    let movieDir = root.appendingPathComponent("电影")
    // 白名单内
    for ext in videoExtensions {
      _ = try writeDummyFile(at: movieDir, name: "video_\(ext).\(ext)")
    }
    // 非视频（应被过滤）
    _ = try writeDummyFile(at: movieDir, name: "promo.png")
    _ = try writeDummyFile(at: movieDir, name: "info.txt")
    _ = try writeDummyFile(at: movieDir, name: "poster.jpg")
    _ = try writeDummyFile(at: movieDir, name: "meta.nfo")

    let items = try MediaLibraryScanner.scan(root: root)

    // 强断言：每个 item 的扩展名 ∈ 白名单
    for item in items {
      let ext = item.url.pathExtension.lowercased()
      XCTAssertTrue(videoExtensions.contains(ext),
                    "扫描结果不得含非视频扩展名，实际出现: \(ext)（url: \(item.url)）")
    }
    // 强断言：白名单 8 种全部命中
    let foundExts = Set(items.map { $0.url.pathExtension.lowercased() })
    XCTAssertEqual(foundExts, videoExtensions,
                   "白名单 8 种扩展名应全部被扫描到，实际: \(foundExts)")
    // 强断言：.png 被过滤（场景 8-P2 同源谓词）
    XCTAssertFalse(items.contains { $0.url.pathExtension.lowercased() == "png" },
                   ".png 必须被过滤，不得出现在扫描结果")
  }

  // MARK: - 场景 8-P2：电视剧目录 .png/.mkv 混合仅保留视频

  /// 谓词: 场景8-P2 [det-machine]: ∀ episode 不匹配 `\.png$`
  func test_scan_tv_show_directory_filters_png() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    let tvDir = root.appendingPathComponent("电视剧")
    let showDir = tvDir.appendingPathComponent("怪奇物语.第五季.Stranger.Things.S05")
    try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
    _ = try writeDummyFile(at: showDir, name: "怪奇物语.S05E01.mkv")
    _ = try writeDummyFile(at: showDir, name: "怪奇物语.S05E02.mkv")
    _ = try writeDummyFile(at: showDir, name: "推广图.png")
    _ = try writeDummyFile(at: showDir, name: "海报.png")

    let items = try MediaLibraryScanner.scan(root: root)

    // 强断言：所有 item 的 url 不以 .png 结尾
    for item in items {
      XCTAssertFalse(item.url.pathExtension.lowercased() == "png",
                     "电视剧目录内 .png 必须被过滤，实际出现: \(item.url.lastPathComponent)")
    }
    // 强断言：mkv 集数被保留
    let mkvCount = items.filter { $0.url.pathExtension.lowercased() == "mkv" }.count
    XCTAssertEqual(mkvCount, 2,
                   "怪奇物语目录应扫到 2 个 mkv 集数，实际: \(mkvCount)")
  }

  // MARK: - 电视剧分组（tvShowId）

  /// 谓词: 契约「电视剧：每个子目录 → 一部剧（tvShowId=清洗后目录名）」
  func test_scan_tv_show_grouping_assigns_tvShowId() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    let tvDir = root.appendingPathComponent("电视剧")
    let showDir = tvDir.appendingPathComponent("怪奇物语.第五季.Stranger.Things.S05")
    try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
    _ = try writeDummyFile(at: showDir, name: "怪奇物语.S05E01.mkv")
    _ = try writeDummyFile(at: showDir, name: "怪奇物语.S05E02.mkv")

    let items = try MediaLibraryScanner.scan(root: root)

    let tvItems = items.filter { $0.category == .tvShow }
    XCTAssertEqual(tvItems.count, 2, "电视剧应扫到 2 集")
    // 强断言：所有电视剧 item 的 tvShowId 非 nil 且一致
    let tvShowIds = Set(tvItems.compactMap { $0.tvShowId })
    XCTAssertEqual(tvShowIds.count, 1, "同一目录的集应归属同一 tvShowId")
    XCTAssertNotNil(tvShowIds.first, "tvShowId 必须非 nil")
    // 强断言：tvShowId 应是清洗后的目录名（含「怪奇物语」）
    if let sid = tvShowIds.first {
      XCTAssertTrue(sid.contains("怪奇物语"),
                    "tvShowId 应为清洗后目录名，含「怪奇物语」，实际: \(sid)")
    }
  }

  // MARK: - 分类映射（电影/电视剧/其它）

  /// 谓词: 契约「读三个固定子目录 电影/电视剧/其它（对应 category）」
  func test_scan_assigns_category_by_fixed_subdirectory() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    _ = try writeDummyFile(at: root.appendingPathComponent("电影"), name: "movie1.mkv")
    let showDir = root.appendingPathComponent("电视剧").appendingPathComponent("show1")
    try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
    _ = try writeDummyFile(at: showDir, name: "show1.E01.mkv")
    _ = try writeDummyFile(at: root.appendingPathComponent("其它"), name: "other1.mp4")

    let items = try MediaLibraryScanner.scan(root: root)

    let movies = items.filter { $0.category == .movie }
    let tvShows = items.filter { $0.category == .tvShow }
    let others = items.filter { $0.category == .other }

    XCTAssertEqual(movies.count, 1, "电影目录应 1 项，实际: \(movies.count)")
    XCTAssertEqual(tvShows.count, 1, "电视剧应 1 集，实际: \(tvShows.count)")
    XCTAssertEqual(others.count, 1, "其它目录应 1 项，实际: \(others.count)")
  }

  // MARK: - 场景 17-P1：空目录显示空状态（cells.count==0）

  /// 谓词: 场景17-P1 [det-machine]: 分类目录为空 → cells.count==0
  func test_scan_empty_directory_returns_empty() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }
    // 三个子目录均为空

    let items = try MediaLibraryScanner.scan(root: root)
    XCTAssertTrue(items.isEmpty,
                  "空目录扫描结果必须为空数组，实际: \(items.count) 项")
  }

  // MARK: - 场景 11-P1/P2：路径不可访问抛 MediaLibraryError.pathNotAccessible

  /// 谓词: 场景11-P1 [det-machine]: 路径不可访问 → 抛 MediaLibraryError.pathNotAccessible
  /// 谓词: 场景11-P2 [det-machine]: 不崩溃且窗口响应（扫描器抛错不 crash）
  func test_scan_inaccessible_root_throws_pathNotAccessible() throws {
    // 指向一个不存在的路径
    let nonexistent = URL(fileURLWithPath: "/Volumes/stringzhao_主空间/this_path_does_not_exist_\(UUID().uuidString)")

    XCTAssertThrowsError(try MediaLibraryScanner.scan(root: nonexistent)) { error in
      // 强断言：必须是 MediaLibraryError.pathNotAccessible
      guard let libError = error as? MediaLibraryError else {
        XCTFail("必须抛 MediaLibraryError 类型，实际抛: \(type(of: error)) — \(error)")
        return
      }
      // 强断言：case 必须是 pathNotAccessible
      if case .pathNotAccessible(let url) = libError {
        XCTAssertEqual(url, nonexistent,
                       "pathNotAccessible 携带的 url 必须与传入根路径一致")
      } else {
        XCTFail("必须抛 .pathNotAccessible case，实际 case: \(libError)")
      }
    }
    // 到此说明未 crash → 场景 11-P2「不崩溃」隐式满足
  }

  // MARK: - Mutation-Survival 自检

  /// No-op 自检：根路径存在但无三个固定子目录 → 返回空（不抛错，不创建子目录）
  func test_scan_root_without_fixed_subdirs_returns_empty_no_throw() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("iina_ml_no_subdirs_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { cleanup(tmp) }

    // 根目录存在但无 电影/电视剧/其它 子目录
    let items = try MediaLibraryScanner.scan(root: tmp)
    XCTAssertTrue(items.isEmpty,
                  "无固定子目录的根应返回空数组，实际: \(items.count)")
  }

  /// Boundary 自检：深层嵌套电视剧目录
  func test_scan_deeply_nested_tv_show() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    let tvDir = root.appendingPathComponent("电视剧")
    let showDir = tvDir.appendingPathComponent("某剧.Show.S01")
    let seasonDir = showDir.appendingPathComponent("Season.1")
    try FileManager.default.createDirectory(at: seasonDir, withIntermediateDirectories: true)
    // CONTRACT_AMBIGUOUS: 设计文档未明确电视剧是否支持季子目录（「只按目录分剧，不做季分组」）。
    // 此处验证单层目录分组；若蓝队支持多层，本用例可放宽。
    _ = try writeDummyFile(at: showDir, name: "某剧.S01E01.mkv")

    let items = try MediaLibraryScanner.scan(root: root)
    let tvItems = items.filter { $0.category == .tvShow }
    XCTAssertGreaterThanOrEqual(tvItems.count, 1, "电视剧应至少扫到 1 集")
  }

  /// State-Update Skip 自检：重复扫描结果稳定（幂等）
  func test_scan_idempotent_on_unchanged_directory() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    _ = try writeDummyFile(at: root.appendingPathComponent("电影"), name: "movie1.mkv")

    let first = try MediaLibraryScanner.scan(root: root)
    let second = try MediaLibraryScanner.scan(root: root)

    XCTAssertEqual(first.count, second.count,
                   "同一目录重复扫描结果数量必须一致（幂等）")
  }
}
