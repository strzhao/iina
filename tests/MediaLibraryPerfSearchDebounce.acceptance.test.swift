//
//  MediaLibraryPerfSearchDebounce.acceptance.test.swift
//  iina
//
//  红队验收测试 — P2 搜索 150ms debounce（黑盒视角）
//
//  覆盖谓词：
//    P2.1 [det-machine] 连续输入（<=30ms x 10）期间 reloadDataCallCount 增量 <= 2
//    P2.2 [det-machine] 停止 >=300ms 后 reloadDataCallCount 增量 == 1
//    P2.3 [det-machine] 搜索结果 == reference lowercased 子串集合
//    P2.4 [det-machine] 清空搜索恢复全量（displayed == total）
//
//  设计文档声明 seam（均 internal；本测试断言这些）：
//    MediaLibraryViewController.reloadDataCallCount: Int  // 每次 reloadData() 前 += 1
//    searchDebounceInterval == 0.15 (s)
//    currentFilter 立即更新（终态语义正确）；refresh() 被 debounce
//    空字符串与非空走同一 debounce 路径，无 fast-path 短路（I4）
//
//  注：searchField 是 NSSearchField，每字符发送 action（sendsSearchStringImmediately==true）。
//      本测试直接构造 VC，调用 searchChanged 的等价入口（修改 currentFilter + 调 refresh 的防抖路径）。
//      VC.searchField 是 private，因此通过 NSSearchField 实例 + target/action 模拟（与生产一致）。
//

import XCTest
@testable import IINA

final class MediaLibraryPerfSearchDebounceAcceptanceTests: XCTestCase {

  // MARK: - 辅助

  private func makeItem(_ name: String, category: MediaCategory = .movie) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_p2_\(UUID().uuidString).mkv"),
      cleanedName: name,
      rawName: name + ".mkv",
      category: category,
      tvShowId: nil,
      episodeNumber: nil,
      duration: 100,
      thumbnailPath: nil
    )
  }

  /// 构造 VC，注入固定 displayedItems 基线（让 refresh 的查询有源）。
  private func makeVCWithItems(_ items: [MediaItem]) -> MediaLibraryViewController {
    MediaLibraryStore.disableRescanForTesting = true  // 测试隔离：禁 rescan 避免扫真 NAS
    MediaLibraryStore.shared.setItemsForTesting(items)
    let vc = MediaLibraryViewController()
    // 触发 loadView + viewDidLoad：viewDidLoad 调 refresh 装载 items + 注册通知（rescan 被 seam 禁）
    _ = vc.view
    return vc
  }

  // MARK: - P2.1 连续输入（<=30ms x 10）期间 reloadDataCallCount 增量 <= 2
  // 契约：searchDebounceInterval == 0.15 s。连续输入（<=30ms 间隔，模拟人类快速打字）期间
  //       reloadData 增量 <= 2（边界穿越，最多跨过一次 debounce 窗口）。
  // 边界值（## 契约规约 边界值）：连续输入（<=30ms 间隔）期间 reloadDataCallCount 增量 <= 2。

  /// 谓词: P2.1 [det-machine] 连续输入防抖
  /// WHEN 在 <=30ms 间隔内连续输入 10 字符（每字符触发 searchChanged → schedule refresh），
  /// THEN reloadDataCallCount 增量 <= 2（150ms debounce 窗口合并连续输入）。
  func test_continuous_input_debounces_reloadData() {
    let items = (0..<20).map { makeItem("电影\($0)") }
    let vc = makeVCWithItems(items)

    let initialCount = vc.reloadDataCallCount

    // 模拟快速连续输入 10 个字符（每 <=30ms 一字符）
    // searchField 是 NSSearchField，调 searchChanged(_:) 的等价路径：直接 performAction
    // 但 searchField 是 VC 私有，无法直接拿到。契约 seam 是「searchChanged 调 refresh 被 debounce」
    // 实现侧：searchChanged 内 currentFilter = sender.stringValue; scheduleDebouncedRefresh()
    // 红队可观测 seam：reloadDataCallCount（每次 refresh 内 reloadData 前自增）
    // 路径：直接设置 currentFilter 后调 VC.searchChanged 对应的公开触发器
    // CONTRACT_SEAM: VC 无 public search 入口；按生产路径用 NSSearchField + action
    // 由于 searchField 私有，回退：用 KVC 取 searchField 或 NSAccessibility 取子视图
    // 设计文档声明 currentFilter 是 internal，直接 set currentFilter 并触发 searchChanged 行为
    // 更直接的方式：复用 VC 内部 search 触发——若蓝队暴露 internal search 入口则用之，
    // 否则通过 NotificationCenter 模拟（VC 监听 NSSearchField action）。
    //
    // 最稳定做法：直接调 refresh()（这是 debounce 包裹的目标，但 refresh 本身是立即执行的）
    // 真正的 debounce 语义在 searchChanged 的 work item 里——红队必须经 searchChanged 路径。
    //
    // CONTRACT_AMBIGUOUS: VC 的 search 触发入口 searchChanged 是 private @objc，
    // 测试无法直接调用。设计文档未声明 internal 的「触发搜索」seam（仅声明 reloadDataCallCount）。
    // 解法：用 NSSearchField target/action 模式（与生产一致）——构造 NSSearchField，
    // target = vc, action = vc.searchChanged 的 selector。
    let searchField = NSSearchField()
    searchField.target = vc
    // selector 是 private，但 NSSearchField action 通过 NSSearchFieldCell 触发，
    // 走 sendsWholeSearchString/sendsSearchStringImmediately 路径。
    // 设计未声明 selector 名暴露——用 NSSearchField.sendsSearchStringImmediately 模拟。
    //
    // 实际可行路径（hosted XCTest）：直接 set currentFilter + 调 vc.refresh() 是 bypass debounce。
    // 真正的 debounce 测试需要 searchChanged 路径。
    //
    // 最务实做法：测试以 currentFilter 的连续变化 + 监听 reloadDataCallCount 增量
    // 为可观测目标——但若 refresh 不被 debounce，增量会 == 10；若 debounce，增量 <= 2。
    // 但要触发 searchChanged 的 debounce 逻辑，必须经过 searchField action。
    //
    // 用 ObjC runtime 取 VC.searchField（已知属性名 searchField）：
    let mirrorSearchField = Mirror(reflecting: vc).children.first { $0.label == "searchField" }?.value as? NSSearchField
    guard let field = mirrorSearchField else {
      XCTFail("P2.1 CONTRACT_SEAM 缺失：MediaLibraryViewController.searchField 无法经 Mirror 取得，无法触发 searchChanged 防抖路径")
      return
    }
    field.target = vc
    // NSSearchField action selector 取自 VC（生产设置 #selector(searchChanged(_:))）
    // 假设 VC 已在 init/loadView 设置；若未设置，此处显式复用：
    // selector 名 searchChanged: 是 @objc，可用 NSSelectorFromString
    let sel = NSSelectorFromString("searchChanged:")
    field.action = sel

    // 快速连续输入 10 字符（"abcdefghij"），每字符 <=30ms 间隔
    let chars: [String] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
    for ch in chars {
      field.stringValue += ch
      // 触发 action（模拟用户输入）—— perform(_:with:) 经 ObjC runtime 调 @objc searchChanged
      _ = field.target?.perform(sel, with: field)
      // <=30ms 间隔（同步循环天然满足，不睡眠）
    }

    // 不等太长（避免跨 debounce 窗口产生额外 reload）
    // 此时刚打完 10 字符，150ms 窗口尚未 fire
    let countDuringTyping = vc.reloadDataCallCount - initialCount

    XCTAssertLessThanOrEqual(
      countDuringTyping, 2,
      "P2.1 违反：连续输入 10 字符期间 reloadDataCallCount 增量 = \(countDuringTyping) > 2"
      + "（150ms debounce 应合并连续输入，最多跨 1 个窗口边界产生 2 次 reload）"
    )

    // 等合并窗口 + 余量 fire，确保最终 1 次 reload 触发（防残留 schedule 影响 tearDown）
    let exp = expectation(description: "debounce fire")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { exp.fulfill() }
    wait(for: [exp], timeout: 2.0)
  }

  // MARK: - P2.2 停止 >=300ms 后 reloadDataCallCount 增量 == 1
  // 边界值：停止输入 >=300ms 后 reloadDataCallCount 增量 == 1。

  /// 谓词: P2.2 [det-machine] 停止后恰好一次 refresh
  /// WHEN 输入若干字符后停止 >=300ms，
  /// THEN reloadDataCallCount 增量 == 1（150ms debounce fire 一次，之后不再重复）。
  func test_after_input_stops_exactly_one_reload_fires() {
    let items = (0..<10).map { makeItem("P2.2-\($0)") }
    let vc = makeVCWithItems(items)

    let mirrorSearchField = Mirror(reflecting: vc).children.first { $0.label == "searchField" }?.value as? NSSearchField
    guard let field = mirrorSearchField else {
      XCTFail("P2.2 CONTRACT_SEAM 缺失：MediaLibraryViewController.searchField 无法取得")
      return
    }
    field.target = vc
    field.action = NSSelectorFromString("searchChanged:")

    // 停止前的基线
    let baselineBeforeStop = vc.reloadDataCallCount

    // 连续输入 3 字符后停止
    for ch in ["a", "b", "c"] {
      field.stringValue += ch
      _ = field.target?.perform(NSSelectorFromString("searchChanged:"), with: field)
    }

    // 等 350ms（>=300ms，远超 150ms debounce 窗口）
    let exp = expectation(description: "settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { exp.fulfill() }
    wait(for: [exp], timeout: 2.0)

    let delta = vc.reloadDataCallCount - baselineBeforeStop

    XCTAssertEqual(
      delta, 1,
      "P2.2 违反：停止 >=300ms 后 reloadDataCallCount 增量 = \(delta)（应为恰好 1，"
      + "150ms debounce 应 fire 一次，之后无重复）"
    )
  }

  // MARK: - P2.3 搜索结果 == reference lowercased 子串集合
  // reference oracle：测试内朴素 cleanedName.lowercased().contains(needle)。

  /// 谓词: P2.3 [det-machine] 搜索结果 == reference
  /// WHEN 设置 currentFilter = needle 后 refresh，
  /// THEN displayedItems == 用 reference oracle (cleanedName.lowercased().contains(needle)) 计算的集合。
  func test_search_results_match_reference_lowercase_substring() {
    // 覆盖大小写 / 中文 / 符号
    let items = [
      makeItem("Inception"),
      makeItem("inception 2"),
      makeItem("盗梦空间"),
      makeItem("Movie [2024]"),
      makeItem("Other Movie"),
    ]
    let vc = makeVCWithItems(items)
    vc.currentCategory = .movie

    for needle in ["INCEP", "incep", "盗梦", "[2024]", "movie 2"] {
      vc.currentFilter = needle
      vc.refresh()

      // reference oracle
      let lowerNeedle = needle.lowercased()
      let reference = items.filter { $0.cleanedName.lowercased().contains(lowerNeedle) }
      let referenceURLs = Set(reference.map { $0.url })
      let actualURLs = Set(vc.displayedItems.map { $0.url })

      XCTAssertEqual(
        actualURLs, referenceURLs,
        "P2.3 违反：needle=\(needle) 时搜索结果与 reference 不一致。"
        + "actual=\(vc.displayedItems.map { $0.cleanedName }) reference=\(reference.map { $0.cleanedName })"
      )
    }
  }

  // MARK: - P2.4 清空搜索恢复全量：displayed == total
  // 契约：空字符串与非空走同一 debounce 路径，无 fast-path 短路（I4）。
  // 清空搜索后 displayedItems.count == 全量 items.count。

  /// 谓词: P2.4 [det-machine] 清空搜索恢复全量
  /// WHEN currentFilter 从非空变为空字符串并 refresh，
  /// THEN displayedItems.count == 该 category 下全量 items.count。
  func test_clear_search_restores_full_list() {
    let items = (0..<5).map { makeItem("P2.4-movie-\($0)") }
    let vc = makeVCWithItems(items)
    vc.currentCategory = .movie

    // 先输入一个 filter 收窄
    vc.currentFilter = "movie-1"
    vc.refresh()
    XCTAssertLessThan(
      vc.displayedItems.count, items.count,
      "前置失败：filter 应收窄结果集"
    )

    // 清空搜索
    vc.currentFilter = ""
    vc.refresh()

    XCTAssertEqual(
      vc.displayedItems.count, items.count,
      "P2.4 违反：清空搜索后 displayedItems.count=\(vc.displayedItems.count) != 全量 \(items.count)"
      + "（空字符串与非空应走同一查询路径，无 fast-path 短路）"
    )
  }
}
