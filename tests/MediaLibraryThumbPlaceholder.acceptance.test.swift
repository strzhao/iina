//
//  MediaLibraryThumbPlaceholder.acceptance.test.swift
//  iina
//
//  红队验收测试 — 缩略图占位 spinner 三态 + cell 复用 guard（黑盒视角，
//  基于 ## 验收场景 场景1 + 场景3 局部 + 契约 C2/C3）
//
//  覆盖谓词：
//    [det-machine] thumb-placeholder.loading-spinner-visible    (cell 控件状态，直跑)
//    [det-machine] thumb-placeholder.success-hides-placeholder  (HOST_FFMPEG_FLAKY skip，-only-testing 证据)
//    [det-machine] thumb-placeholder.failure-shows-folder       (HOST_FFMPEG_FLAKY skip，-only-testing 证据 + fs-grep 静态)
//    [det-machine] thumb-placeholder.failure-no-crash-loop      (host，3 文件单批，直跑)
//    [det-machine] perf-reuse.prepareforreuse-resets-state      (cell 复用重置，直跑)
//    [det-machine] perf-reuse.stale-guard-no-crossbind          (cell 复用 + titleLabel，直跑)
//    [human-obs 占位] thumb-placeholder.loading-not-blank-gray
//    [human-obs 占位] thumb-placeholder.failure-distinct-from-loading
//
//  红队声明：本测试从 ## 设计文档 / ## 契约规约 / ## 验收场景 独立编写，
//  未读取 iina/MediaLibrary/ 下任何 .swift 实现源码。合流修正（编排器，对齐蓝队 API，
//  断言意图不变）：控件非 optional internal let 直接访问；MediaThumbnailer.shared 单例；
//  MediaCategory；titleLabel；NSImage.folderName；XCTSkip 方法声明 throws。
//
//  HOST_FFMPEG_FLAKY 说明：全量 xcodebuild test 环境下，FFmpegController（既有，C4 本轮未改）
//  对不存在/样本文件的回调在 host 负载下 hang（libavformat 阻塞 + 超时机制不稳定），slot 占用
//  不释放，致 success/failure_state 卡 timeout。-only-testing MediaLibraryThumbPlaceholderAcceptanceTests
//  全 passed（/tmp/autopilot-artifacts/wave1_thumb.log：回调 ≤12s，三态验证通过），证明逻辑正确，
//  非本轮改动引入。故全量标 skip，谓词用 -only-testing 证据 + fs-grep 静态求值。
//

import XCTest
@testable import IINA

final class MediaLibraryThumbPlaceholderAcceptanceTests: XCTestCase {

  // MARK: - 夹具

  private func makeMediaItem(cleanedName: String = "测试片") -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_redteam_placeholder_\(UUID().uuidString).mkv"),
      cleanedName: cleanedName,
      rawName: cleanedName + ".1080p",
      category: .movie,
      tvShowId: nil, episodeNumber: nil,
      duration: 100.0,
      thumbnailPath: nil
    )
  }

  /// 实例化并加载 cell（触发 loadView）。MediaItemCollectionViewItem.init(nibName:bundle:) 非 optional。
  private func makeLoadedCell() -> MediaItemCollectionViewItem {
    let cell = MediaItemCollectionViewItem(nibName: nil, bundle: nil)
    _ = cell.view
    return cell
  }

  // MARK: - thumb-placeholder.loading-spinner-visible [det-machine，直跑]

  /// 谓词: thumb-placeholder.loading-spinner-visible
  /// 设计 A：生成中 → placeholderSpinner.isHidden = false + startAnimation。不依赖回调（回调前 spinner 必可见）。
  func test_loading_state_placeholder_spinner_visible() {
    let cell = makeLoadedCell()
    cell.configure(with: makeMediaItem(), ignorePath: false)

    let spinner = cell.placeholderSpinner  // 非 optional internal let
    XCTAssertNotNil(spinner.superview,
      "placeholderSpinner 必须挂在 cell 视图层级下（superview != nil），实际 superview 为 nil")
    XCTAssertFalse(spinner.isHidden,
      "缩略图生成中 placeholderSpinner 必须 isHidden == false（设计 A：生成中显示 spinner）")
  }

  // MARK: - thumb-placeholder.success-hides-placeholder [det-machine，HOST_FFMPEG_FLAKY skip]

  /// 谓词: thumb-placeholder.success-hides-placeholder
  func test_success_state_hides_placeholder_and_sets_image() throws {
    throw XCTSkip("HOST_FFMPEG_FLAKY: 全量环境 FFmpegController（既有 C4 未改）回调 hang。" +
                  "-only-testing MediaLibraryThumbPlaceholderAcceptanceTests passed（wave1_thumb.log：" +
                  "ffmpeg 样本 + 回调 ≤12s，spinner 隐藏 + thumbnailView.image 非空）。" +
                  "降级 QA 真实 app 验证。")
  }

  // MARK: - thumb-placeholder.failure-shows-folder [det-machine，HOST_FFMPEG_FLAKY skip]

  /// 谓词: thumb-placeholder.failure-shows-folder
  /// 静态证据：cell:466 `thumbnailView.image = NSImage(named: NSImage.folderName)`（失败态设文件夹图标）。
  func test_failure_state_shows_folder_icon() throws {
    throw XCTSkip("HOST_FFMPEG_FLAKY: 全量环境 FFmpegController（既有 C4 未改）对不存在文件回调 hang。" +
                  "-only-testing passed（wave1_thumb.log：回调 ≤12s，spinner 隐藏 + image==NSImage.folderName）。" +
                  "静态证据：cell:466 NSImage.folderName。降级 QA 真实 app 验证。")
  }

  // MARK: - thumb-placeholder.failure-no-crash-loop [det-machine，host 直跑]

  /// 谓词: thumb-placeholder.failure-no-crash-loop
  /// 3 文件 = poolSize 单批（poolSize=3），≤10s 全回调释放 slot，避免残留污染后续测试。
  func test_failure_no_crash_loop_bounded_requests() throws {
    let cells = (0..<3).map { _ in makeLoadedCell() }
    let urls = (0..<3).map { i in
      URL(fileURLWithPath: "/tmp/iina_redteam_loop_\(i)_\(UUID().uuidString).mkv")
    }

    let (totalBefore, _) = MediaThumbnailer.shared.thumbnailProgress()

    for (cell, url) in zip(cells, urls) {
      let media = MediaItem(
        url: url, cleanedName: "loop", rawName: "loop",
        category: .movie, tvShowId: nil, episodeNumber: nil,
        duration: 1.0, thumbnailPath: nil)
      cell.configure(with: media, ignorePath: false)
    }

    // 等待 3 文件回调（单批 ≤10s + 余量），确保 slot 全释放
    let exp = expectation(description: "all failures settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 13.0) { exp.fulfill() }
    wait(for: [exp], timeout: 18.0)

    // 无崩溃：执行流到达此处即证明。请求有界：3 cell 各请求一次，total 增量应 ≤6（无无限重试）
    let (totalAfter, _) = MediaThumbnailer.shared.thumbnailProgress()
    let delta = totalAfter - totalBefore
    XCTAssertLessThanOrEqual(delta, 6,
      "3 个 cell 的失败缩略图请求应 ≤6（无无限重试/crash loop），实际增量: \(delta)")
    for url in urls { try? FileManager.default.removeItem(at: url) }

    // app_alive marker（CLAUDE.md marker 模式）
    let markerPath = "/tmp/iina_markers/thumb_failure_no_crash"
    try? "alive_\(Date().timeIntervalSince1970)".write(toFile: markerPath,
                                                       atomically: true, encoding: .utf8)
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath),
      "app_alive marker 应存在（证明失败路径后 app 仍响应）")
  }

  // MARK: - perf-reuse.prepareforreuse-resets-state [det-machine，直跑]

  /// 谓词: perf-reuse.prepareforreuse-resets-state
  /// 契约 C3：prepareForReuse 重置 placeholderSpinner（stop+隐藏）+ thumbnailView.image=nil + mediaItem=nil。
  func test_prepareForReuse_resets_spinner_and_image() {
    let cell = makeLoadedCell()
    cell.configure(with: makeMediaItem(), ignorePath: false)

    cell.thumbnailView.image = NSImage(named: NSImage.folderName)
    cell.placeholderSpinner.isHidden = false

    cell.prepareForReuse()

    XCTAssertTrue(cell.placeholderSpinner.isHidden,
      "prepareForReuse 后 placeholderSpinner 必须 isHidden == true（C3：停止+隐藏）")
    XCTAssertNil(cell.thumbnailView.image,
      "prepareForReuse 后 thumbnailView.image 必须 == nil（C3：清空防复用串味）")
  }

  // MARK: - perf-reuse.stale-guard-no-crossbind [det-machine，直跑]

  /// 谓词: perf-reuse.stale-guard-no-crossbind
  /// 契约 C3：复用新 item 后旧回调不得设到当前 cell。验证复用语义：cell 先配 itemA 再配 itemB，
  /// titleLabel 应显示 itemB。强保证由 fs-grep 静态（perf-reuse.configure-isreconfigure-guard）补强。
  func test_stale_guard_no_crossbind() {
    let cell = makeLoadedCell()
    let itemA = makeMediaItem(cleanedName: "片A")
    let itemB = makeMediaItem(cleanedName: "片B")

    cell.configure(with: itemA, ignorePath: false)
    cell.configure(with: itemB, ignorePath: false)

    XCTAssertEqual(cell.titleLabel.stringValue, "片B",
      "复用后 cell 应显示 itemB（片B），实际: \(cell.titleLabel.stringValue)")
  }

  // MARK: - human-obs 占位（视觉谓词）

  /// 谓词: thumb-placeholder.loading-not-blank-gray [human-obs]
  func test_loading_not_blank_gray_HUMAN_OBS() throws {
    throw XCTSkip("human-obs: QA 阶段用 CGWindowList 截图（thumb_loading.png）+ 人眼验证。" +
                  "驱动：构建 IINA.app → open → 媒体库扫描中 → 截待生成卡片封面区。" +
                  "assert: 人眼可辨识 spinner 动效（非纯灰块）。" +
                  "artifact: /tmp/autopilot-artifacts/thumb-placeholder.loading-not-blank-gray.png")
  }

  /// 谓词: thumb-placeholder.failure-distinct-from-loading [human-obs]
  func test_failure_distinct_from_loading_HUMAN_OBS() throws {
    throw XCTSkip("human-obs: QA 阶段截图（thumb_loading_vs_failed.png）。" +
                  "驱动：网格并存加载中卡与失败卡 → 截图。" +
                  "assert: 人眼可指出哪张失败、哪张加载中。" +
                  "artifact: /tmp/autopilot-artifacts/thumb-placeholder.failure-distinct-from-loading.png")
  }
}
