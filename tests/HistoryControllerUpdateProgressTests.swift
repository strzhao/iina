//
//  HistoryControllerUpdateProgressTests.swift
//  iinaTests
//
//  蓝队自写单元测试 — 修复 A3 / C1 契约：
//  HistoryController.add 把旧 entry 的 mpvProgress 迁移到新 entry（不被 init 默认 nil 覆盖）；
//  新增 updateProgress(url:progress:) 走 queue.async + $history.withLock；新增 waitForDrain() 测试 seam。
//
//  注意：mpvMd5 由 Utility.mpvWatchLaterMd5(url, ignorePath) 计算，不是测试硬编码的字符串。
//  所有断言用 url 匹配（add 内部用 mpvMd5 去重，url 是唯一稳定标识）。
//

import XCTest
@testable import IINA

final class HistoryControllerUpdateProgressTests: XCTestCase {

  /// 用临时 plist 构造独立 HistoryController（不污染生产 history.plist）。
  private func makeIsolatedController() -> (controller: HistoryController, plistURL: URL) {
    // 确保 add 不被 recordPlaybackHistory guard 拦截（test 环境下 preference 可能未初始化）。
    Preference.set(true, for: .recordPlaybackHistory)
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("iina_hist_test_\(UUID().uuidString).plist")
    let controller = HistoryController(plistFileURL: tmp)
    return (controller, tmp)
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// 谓词 A3.1：add remove 旧条目前迁移 mpvProgress 到新条目。
  /// 场景：同一 url 的旧 entry 已有 mpvProgress，再次 add（如重播）时新 entry 必须继承旧进度，
  /// 禁止被 init 默认 nil 覆盖（否则 updateProgress 之前的历史进度会丢失）。
  func test_add_preserves_existing_mpvProgress() throws {
    let (controller, plist) = makeIsolatedController()
    defer { cleanup(plist) }

    let url = URL(fileURLWithPath: "/tmp/iina_hist_migrate_\(UUID().uuidString).mkv")

    // 第一次 add：建立 entry（mpvProgress == nil，因为没 watch-later 文件）。
    controller.add(url, duration: 3600, title: "t", false)
    controller.waitForDrain()

    // 手动设置 mpvProgress（模拟 updateProgress 已回写过）。
    try controller.$history.withLock { history in
      if let idx = history.firstIndex(where: { $0.url == url }) {
        history[idx].mpvProgress = VideoTime(250.0)
      }
    }

    // 第二次 add 同 url：新 entry 必须继承旧 entry 的 mpvProgress=250.0。
    controller.add(url, duration: 3600, title: "t", false)
    controller.waitForDrain()

    let entries = controller.history.filter { $0.url == url }
    XCTAssertEqual(entries.count, 1, "同 url 只应保留最新一个 entry")
    XCTAssertEqual(entries.first?.mpvProgress?.second ?? -1, 250.0, accuracy: 0.001,
                   "add 必须迁移旧 entry 的 mpvProgress 到新 entry（禁止被 init 默认 nil 覆盖）")
  }

  /// 谓词 A3.2 / C1：updateProgress(url:progress:) 更新已存在 entry 的 mpvProgress，
  /// 通过 queue.async + $history.withLock 调度（TSan 安全）。
  func test_updateProgress_updates_existing_entry() throws {
    let (controller, plist) = makeIsolatedController()
    defer { cleanup(plist) }

    let url = URL(fileURLWithPath: "/tmp/iina_hist_update_\(UUID().uuidString).mkv")
    controller.add(url, duration: 3600, title: "t", false)
    controller.waitForDrain()

    // 初始无 mpvProgress。
    XCTAssertEqual(controller.history.first { $0.url == url }?.mpvProgress?.second ?? -1, -1,
                   accuracy: 0.001)

    controller.updateProgress(url: url, progress: VideoTime(750.5))
    controller.waitForDrain()

    XCTAssertEqual(controller.history.first { $0.url == url }?.mpvProgress?.second ?? -1,
                   750.5, accuracy: 0.001,
                   "updateProgress 必须把 mpvProgress 写入对应 entry")
  }

  /// 谓词 A3.3：updateProgress 对不存在的 entry 静默跳过（不创建新条目）。
  func test_updateProgress_no_op_for_missing_entry() throws {
    let (controller, plist) = makeIsolatedController()
    defer { cleanup(plist) }

    let url = URL(fileURLWithPath: "/tmp/iina_hist_missing_\(UUID().uuidString).mkv")
    controller.updateProgress(url: url, progress: VideoTime(100.0))
    controller.waitForDrain()

    XCTAssertTrue(controller.history.isEmpty || controller.history.allSatisfy { $0.url != url },
                  "updateProgress 对不存在的 entry 不得创建新条目")
  }

  /// 谓词 A3.4 / C1：waitForDrain() 阻塞直到 queue 中所有任务完成。
  /// 间接验证：连续 add 后 waitForDrain → 所有写入可见。
  func test_waitForDrain_blocks_until_queue_empty() throws {
    let (controller, plist) = makeIsolatedController()
    defer { cleanup(plist) }

    for i in 0..<5 {
      let url = URL(fileURLWithPath: "/tmp/iina_drain_\(i)_\(UUID().uuidString).mkv")
      controller.add(url, duration: 3600.0, title: "t", false)
    }
    controller.waitForDrain()

    XCTAssertEqual(controller.history.count, 5,
                   "waitForDrain 后所有 5 次 add 必须都已落盘到 in-memory history")
  }

  /// 谓词 A3.5：updateProgress 后 save 持久化到 plist（reload 后仍能读到）。
  func test_updateProgress_persists_to_plist() throws {
    let (controller, plist) = makeIsolatedController()
    defer { cleanup(plist) }

    let url = URL(fileURLWithPath: "/tmp/iina_persist_\(UUID().uuidString).mkv")
    controller.add(url, duration: 3600, title: "t", false)
    controller.waitForDrain()
    controller.updateProgress(url: url, progress: VideoTime(300.0))
    controller.waitForDrain()

    // 新建第二个 controller 读同一 plist。
    let controller2 = HistoryController(plistFileURL: plist)
    let entry = controller2.history.first { $0.url == url }
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.mpvProgress?.second ?? -1, 300.0, accuracy: 0.001,
                   "updateProgress 写入的 mpvProgress 必须通过 save 持久化到 plist")
  }
}
