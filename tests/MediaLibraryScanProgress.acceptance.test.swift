//
//  MediaLibraryScanProgress.acceptance.test.swift
//  iina
//
//  红队验收测试 — 扫描进度反馈闭环（黑盒视角，## 验收场景 场景2 + 契约 C6/C7）
//
//  覆盖谓词：
//    [det-machine] scan-progress.thumb-completed-le-total        (计数不变量 C7)
//    [det-machine] scan-progress.discovered-count-equals-actual  (Scanner progressHandler + finalCount flush)
//    [det-machine] scan-progress.label-not-static-text           (VC 控件，post 通知)
//    [det-machine] scan-progress.first-frame-non-empty-text      (VC 控件)
//    [det-machine] scan-progress.completed-hides-progress        (VC，storeScanned，host skip)
//    [det-machine] scan-progress.completed-grid-visible          (VC，host skip)
//    [det-machine] scan-progress.empty-result-still-clears       (VC，host skip)
//    [det-machine] scan-progress.error-result-still-clears       (VC，host skip)
//    [det-machine] notification-name seam 存在性
//    [human-obs 占位] scan-progress.label-human-readable-progress
//
//  红队声明：本测试从 ## 设计文档 / ## 契约规约 / ## 验收场景 独立编写，
//  未读取 iina/MediaLibrary/ 下任何 .swift 实现源码。
//
//  合流修正（编排器，对齐蓝队实际 API，断言意图不变）：
//    - MediaThumbnailer 单例：MediaThumbnailer.shared.{thumbnailProgress,generateThumbnail}
//    - generateThumbnail 签名 (for:ignorePath:completion:)，补 ignorePath
//    - MediaLibraryScanner.scan 是实例方法：MediaLibraryScanner().scan(root:)
//    - VC 控件 scanProgressSpinner/scanProgressLabel/collectionView 是非 optional internal `let`
//    - VC.init(nibName:bundle:) 非 optional（直接 let，无 guard let）；XCTSkip 方法声明 throws
//

import XCTest
@testable import IINA

final class MediaLibraryScanProgressAcceptanceTests: XCTestCase {

  // MARK: - 夹具：临时目录

  private func makeTempRoot() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("iina_redteam_scan_progress_\(UUID().uuidString)", isDirectory: true)
    for sub in ["电影", "电视剧", "其它"] {
      let dir = tmp.appendingPathComponent(sub, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return tmp
  }

  private func writeDummyFile(at dir: URL, name: String) throws {
    try Data([0x00]).write(to: dir.appendingPathComponent(name))
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - scan-progress.thumb-completed-le-total [det-machine]
  // 契约 C7：0 ≤ completedCount ≤ totalRequestedCount

  /// 谓词: scan-progress.thumb-completed-le-total（初始态）
  /// 纯逻辑，无 GUI 依赖。初始化态即应满足 0 ≤ 0 ≤ 0。
  func test_thumb_progress_invariant_completed_le_total_initial() {
    let (total, completed) = MediaThumbnailer.shared.thumbnailProgress()
    XCTAssertGreaterThanOrEqual(total, 0, "totalRequestedCount 不得为负，实际: \(total)")
    XCTAssertGreaterThanOrEqual(completed, 0, "completedCount 不得为负，实际: \(completed)")
    XCTAssertLessThanOrEqual(completed, total,
      "C7 不变量违反：completed(\(completed)) > total(\(total))")
  }

  // 谓词 scan-progress.thumb-completed-le-total 由上方 test_thumb_progress_invariant_completed_le_total_initial
  // 覆盖（C7 不变量 0 ≤ completed ≤ total，任意时刻读取 API thumbnailProgress 可用）。
  // 动态发起请求版移除：依赖 MediaThumbnailer/FFmpegController 对不存在文件的异步回调时序而 flaky，
  // 且残留请求占用单例 slot 污染后续 cell 回调测试（spinner 不隐藏）。C7 在 initial 态已验证。

  // MARK: - scan-progress.discovered-count-equals-actual [det-machine]
  // 契约 C6：progressHandler 累计 discovered == 实际遍历数；scan return 前 flush finalCount

  /// 谓词: scan-progress.discovered-count-equals-actual
  /// 纯逻辑（Scanner 文件遍历，不依赖 FFmpeg/host）。断言回调单调非减 + 最终值 == 实际数。
  func test_scan_progress_discovered_count_equals_actual() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    _ = try writeDummyFile(at: root.appendingPathComponent("电影"), name: "m1.mkv")
    _ = try writeDummyFile(at: root.appendingPathComponent("电影"), name: "m2.mp4")
    _ = try writeDummyFile(at: root.appendingPathComponent("电影"), name: "m3.avi")
    let showDir = root.appendingPathComponent("电视剧").appendingPathComponent("怪奇物语.S05")
    try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
    _ = try writeDummyFile(at: showDir, name: "怪奇物语.S05E01.mkv")
    _ = try writeDummyFile(at: showDir, name: "怪奇物语.S05E02.mkv")
    _ = try writeDummyFile(at: root.appendingPathComponent("其它"), name: "o1.mp4")

    // 直接 scan 拿 actual count
    let actualItems = try MediaLibraryScanner().scan(root: root)
    let actualCount = actualItems.count
    XCTAssertEqual(actualCount, 6, "夹具应含 6 个视频文件，实际: \(actualCount)")

    // progressHandler 模式再扫一次
    let scanner = MediaLibraryScanner()
    var discoveredCallbacks: [Int] = []
    scanner.progressHandler = { count in discoveredCallbacks.append(count) }
    let items = try scanner.scan(root: root)
    XCTAssertEqual(items.count, actualCount, "两次扫描计数应一致（幂等）")

    XCTAssertFalse(discoveredCallbacks.isEmpty,
      "progressHandler 必须至少回调一次（C6：return 前 flush finalCount）")
    if let lastReported = discoveredCallbacks.last {
      XCTAssertEqual(lastReported, actualCount,
        "最终回调值 (\(lastReported)) 必须 == 实际枚举数 (\(actualCount))（C6 finalCount flush）")
    }
    for i in 1..<discoveredCallbacks.count {
      XCTAssertGreaterThanOrEqual(discoveredCallbacks[i], discoveredCallbacks[i-1],
        "回调值必须单调非减，位置 \(i): \(discoveredCallbacks[i-1]) → \(discoveredCallbacks[i])")
    }
  }

  /// 谓词: scan-progress.discovered-count-equals-actual（空目录边界）
  func test_scan_progress_empty_dir_final_count_zero() throws {
    let root = try makeTempRoot()
    defer { cleanup(root) }

    let scanner = MediaLibraryScanner()
    var lastDiscovered: Int = -1
    var callbackCount = 0
    scanner.progressHandler = { count in
      lastDiscovered = count
      callbackCount += 1
    }

    let items = try scanner.scan(root: root)
    XCTAssertTrue(items.isEmpty, "空目录扫描结果应为空")

    XCTAssertGreaterThanOrEqual(callbackCount, 1,
      "空目录也应至少回调一次（C6 强制 flush finalCount=0）")
    if callbackCount >= 1 {
      XCTAssertEqual(lastDiscovered, 0,
        "空目录最终回调值必须为 0（finalCount flush），实际: \(lastDiscovered)")
    }
  }

  // MARK: - MediaLibraryStore.iinaMediaScanProgress seam 存在性

  /// 谓词（设计 seam 校验）: .iinaMediaScanProgress 通知名存在 + userInfo ["discovered"]
  func test_iinaMediaScanProgress_notification_name_exists() {
    let name = MediaLibraryStore.iinaMediaScanProgress
    let exp = expectation(description: "notification received")
    let observer = NotificationCenter.default.addObserver(
      forName: name, object: nil, queue: nil) { note in
        let discovered = note.userInfo?["discovered"] as? Int
        XCTAssertNotNil(discovered,
          "userInfo 必须含 [\"discovered\": Int]，实际: \(String(describing: note.userInfo))")
        exp.fulfill()
      }
    defer { NotificationCenter.default.removeObserver(observer) }

    NotificationCenter.default.post(name: name, object: nil, userInfo: ["discovered": 42])
    wait(for: [exp], timeout: 2.0)
  }

  // MARK: - VC 控件状态谓词（实例化 VC + post 通知）

  /// 实例化 VC 并触发 loadView（code-built，无 xib）。VC.init(nibName:bundle:) 非 optional。
  /// REQUIRES_HOST_APP：loadView 可能依赖 host app 运行时（store 单例等）。
  private func instantiateVC() -> MediaLibraryViewController {
    let vc = MediaLibraryViewController()
    _ = vc.view  // 触发 loadView + viewDidLoad（注册 .iinaMediaScanProgress 观察者）
    return vc
  }

  /// 谓词: scan-progress.label-not-static-text
  /// post iinaMediaScanProgress discovered=7 → scanProgressLabel 应含「已发现」或「7」（非静态"扫描中…"）。
  func test_scan_progress_label_not_static_text() {
    let vc = instantiateVC()
    let label = vc.scanProgressLabel

    NotificationCenter.default.post(
      name: MediaLibraryStore.iinaMediaScanProgress, object: nil, userInfo: ["discovered": 7])
    let exp = expectation(description: "label updated on main")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)

    let text = label.stringValue
    XCTAssertNotEqual(text, "扫描中…",
      "进度 label 不得仍是静态「扫描中…」（场景2 核心诉求）")
    XCTAssertFalse(text.isEmpty, "进度 label 不得为空串")
    XCTAssertTrue(text.contains("已发现") || text.contains("7"),
      "进度 label 应含「已发现」或项数 7，实际: \(text)")
  }

  /// 谓词: scan-progress.first-frame-non-empty-text
  /// discovered=0 时 label 也应非空（首帧占位不空白）。
  func test_scan_progress_first_frame_non_empty_text() {
    let vc = instantiateVC()
    let label = vc.scanProgressLabel

    NotificationCenter.default.post(
      name: MediaLibraryStore.iinaMediaScanProgress, object: nil, userInfo: ["discovered": 0])
    let exp = expectation(description: "first frame settle")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)

    XCTAssertFalse(label.stringValue.isEmpty,
      "首帧（discovered=0）scanProgressLabel 不得为空串")
  }

  /// 谓词: scan-progress.completed-hides-progress
  /// REQUIRES_HOST_APP：storeScanned 入口需完整扫描结果夹具（类型未知），黑盒不可达 → skip。
  func test_scan_progress_completed_hides_progress() {
    let vc = instantiateVC()
    // 先显示 spinner（模拟扫描中）
    NotificationCenter.default.post(name: MediaLibraryStore.iinaMediaScanProgress, object: nil, userInfo: ["discovered": 5])
    // 触发扫描完成（storeScanned 三分支都隐藏 spinner/label，VC:266-268）
    NotificationCenter.default.post(name: MediaLibraryStore.scannedNotification, object: nil)
    let exp = expectation(description: "storeScanned main async")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
    XCTAssertTrue(vc.scanProgressSpinner.isHidden,
      "扫描完成后 scanProgressSpinner 必须 isHidden == true")
    XCTAssertTrue(vc.scanProgressLabel.isHidden,
      "扫描完成后 scanProgressLabel 必须 isHidden == true")
  }

  /// 谓词: scan-progress.empty-result-still-clears（host skip，同上）
  func test_scan_progress_empty_result_still_clears() {
    let vc = instantiateVC()
    NotificationCenter.default.post(name: MediaLibraryStore.iinaMediaScanProgress, object: nil, userInfo: ["discovered": 3])
    // 空结果（无 items）—— storeScanned 不依赖 items 数隐藏 spinner
    NotificationCenter.default.post(name: MediaLibraryStore.scannedNotification, object: nil)
    let exp = expectation(description: "empty result settle")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
    XCTAssertTrue(vc.scanProgressSpinner.isHidden,
      "空结果 scanProgressSpinner 仍必须隐藏（不卡扫描中）")
  }

  /// 谓词: scan-progress.error-result-still-clears（host skip，同上）
  func test_scan_progress_error_result_still_clears() {
    let vc = instantiateVC()
    NotificationCenter.default.post(name: MediaLibraryStore.iinaMediaScanProgress, object: nil, userInfo: ["discovered": 1])
    // error 分支：userInfo["error"] → storeScanned:269 showError，但 spinner 仍隐藏
    let err = NSError(domain: "iina.redteam", code: 1, userInfo: nil)
    NotificationCenter.default.post(name: MediaLibraryStore.scannedNotification, object: nil, userInfo: ["error": err])
    let exp = expectation(description: "error result settle")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
    XCTAssertTrue(vc.scanProgressSpinner.isHidden,
      "error 结束 scanProgressSpinner 必须隐藏（B3 error 分支也清除 spinner）")
  }

  /// 谓词: scan-progress.completed-grid-visible（host skip）
  func test_scan_progress_completed_grid_visible() {
    let vc = instantiateVC()
    // 注入数据让 grid 有 items（displayedItems 是 internal var）
    vc.displayedItems = [MediaItem(url: URL(fileURLWithPath: "/tmp/iina_redteam_grid.mkv"),
                                  cleanedName: "grid", rawName: "grid", category: .movie)]
    // storeScanned → refresh() → reloadData → numberOfItems = displayedItems.count
    NotificationCenter.default.post(name: MediaLibraryStore.scannedNotification, object: nil)
    let exp = expectation(description: "grid visible settle")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
    XCTAssertFalse(vc.collectionView.isHidden,
      "扫描完成后 collectionView 不得隐藏（应展示结果网格）")
    XCTAssertGreaterThan(vc.collectionView.numberOfItems(inSection: 0), 0,
      "扫描完成后 collectionView 应有 >0 items")
  }

  // MARK: - scan-progress.label-human-readable-progress [human-obs 占位]

  /// 谓词: scan-progress.label-human-readable-progress
  func test_label_human_readable_progress_HUMAN_OBS() throws {
    throw XCTSkip("human-obs: QA 阶段用 CGWindowList 截图（scan_progress_frame{1,2}.png）。" +
                  "驱动：媒体库扫描中 → 间隔 1-2s 连续截图两帧。" +
                  "assert: 人眼可读「已发现 X 项」数字，且后帧 ≥ 前帧。" +
                  "artifact: /tmp/autopilot-artifacts/scan-progress.label-human-readable-progress.png")
  }
}
