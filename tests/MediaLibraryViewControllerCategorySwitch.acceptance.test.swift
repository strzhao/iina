//
//  MediaLibraryViewControllerCategorySwitch.acceptance.test.swift
//  iina
//
//  红队验收测试 — VC 分类切换不变量 + 动态高度约束（黑盒视角，基于设计文档 ## 契约规约 §3）
//
//  覆盖契约点：
//    1. currentCategory==.tvShow → displayedItems 为「每剧一个代表」
//       （数量 == tvShowGroups 数量；每个代表 tvShowId != nil 且唯一）
//    2. currentCategory==.tvShow → displayedGroupCounts 与 displayedItems 同序同长
//    3. currentCategory==.tvShow → 搜索匹配剧名（通过 store.tvShowGroups(filter:)）
//    4. currentCategory≠.tvShow → displayedItems 为该分类全部 MediaItem，
//       displayedGroupCounts 为空，行为同旧
//    5. 分类切换 → refresh() 重算，displayedItems/displayedGroupCounts 反映新分类
//    6. continueWatchingHeightConstraint.constant == (continueWatchingItems.isEmpty ? 0 : 130)
//       分类切换/搜索/扫描完成/历史更新 → refresh() 重算 constant
//
//  说明：
//    MediaLibraryViewController 是 NSViewController（GUI），依赖 collectionView 渲染、
//    完整 app runtime（PlayerCore/HistoryController/Utility）。
//    纯逻辑层（displayedItems/displayedGroupCounts 数组不变量、constraint constant 值）
//    在 app 链接下可强断言；UI 渲染层（collectionView cells 实际可见性、顶部空白像素）
//    标注 GUI_ACCEPTANCE 留 QA 真机判定。
//

import XCTest
@testable import iina

final class MediaLibraryViewControllerCategorySwitchAcceptanceTests: XCTestCase {

  // MARK: - 夹具

  private let durationSeconds: Double = 100.0

  private func makeEpisode(showId: String, epNum: Int?, cleanedName: String,
                            urlPath: String) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: urlPath),
      cleanedName: cleanedName, rawName: cleanedName + ".1080p",
      category: .tvShow, tvShowId: showId, episodeNumber: epNum,
      duration: durationSeconds, thumbnailPath: nil
    )
  }

  private func makeMovie(cleanedName: String, urlPath: String) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: urlPath),
      cleanedName: cleanedName, rawName: cleanedName + ".1080p",
      category: .movie, tvShowId: nil, episodeNumber: nil,
      duration: durationSeconds, thumbnailPath: nil
    )
  }

  private func injectHistoryEntry(url: URL, progressSeconds: Double, played: Bool, addedDate: Date) {
    let durationVT = VideoTime(durationSeconds)
    let progressVT = VideoTime(progressSeconds)
    let mpvMd5 = Utility.mpvWatchLaterMd5(url, false)
    let entry = PlaybackHistory(
      url: url, name: url.lastPathComponent, mpvMd5: mpvMd5,
      played: played, addedDate: addedDate,
      duration: durationVT, mpvProgress: progressVT, title: nil
    )
    HistoryController.shared.history.append(entry)
  }

  private func cleanupInjectedHistory(prefix: String = "/tmp/iina_redteam_vc_") {
    HistoryController.shared.history.removeAll { $0.url.path.hasPrefix(prefix) }
  }

  override func tearDown() {
    cleanupInjectedHistory()
    super.tearDown()
  }

  // MARK: - VC 实例化辅助

  /// 创建一个 MediaLibraryViewController 并触发 loadView（子视图与约束就绪）
  /// CONTRACT_AMBIGUOUS: VC 的实例化入口（init(coder:) vs init(nibName:bundle:)）。
  ///   若 nib 不存在 loadView 会失败。此处尝试通过 .view 触发 programmatic loadView。
  private func makeVC() -> MediaLibraryViewController? {
    let vc = MediaLibraryViewController(nibName: nil, bundle: nil)
    _ = vc?.view  // 触发 loadView / viewDidLoad
    return vc
  }

  // MARK: - 契约 1+2：currentCategory==.tvShow → 每剧一个代表，displayedGroupCounts 同序

  /// 谓词：切到电视剧分类 → displayedItems.count == tvShowGroups 数量（每剧一个代表）
  /// 且每个代表的 tvShowId 唯一非 nil
  func test_tvShow_category_shows_one_representative_per_show() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 MediaLibraryViewController — GUI_ACCEPTANCE: VC 加载需完整 app 链接"); return
    }
    // 构造 2 剧（3 集 + 2 集），共 5 单集
    let a1 = makeEpisode(showId: "剧A", epNum: 1, cleanedName: "剧A",
                         urlPath: "/tmp/iina_redteam_vc_A1.mkv")
    let a2 = makeEpisode(showId: "剧A", epNum: 2, cleanedName: "剧A",
                         urlPath: "/tmp/iina_redteam_vc_A2.mkv")
    let a3 = makeEpisode(showId: "剧A", epNum: 3, cleanedName: "剧A",
                         urlPath: "/tmp/iina_redteam_vc_A3.mkv")
    let b1 = makeEpisode(showId: "剧B", epNum: 1, cleanedName: "剧B",
                         urlPath: "/tmp/iina_redteam_vc_B1.mkv")
    let b2 = makeEpisode(showId: "剧B", epNum: 2, cleanedName: "剧B",
                         urlPath: "/tmp/iina_redteam_vc_B2.mkv")
    MediaLibraryStore.shared.setItemsForTesting([a1, a2, a3, b1, b2])

    // 切到电视剧分类 + 空 filter（触发 refresh）
    vc.currentCategory = .tvShow
    vc.refresh()

    // 契约 1：displayedItems.count == 2（每剧一个代表），而非 5（全部单集）
    let displayed = vc.displayedItems
    XCTAssertEqual(displayed.count, 2,
                   "电视剧分类 displayedItems 必须每剧一个代表（2），实际: \(displayed.count)")

    // 每个代表 tvShowId 唯一非 nil
    let showIds = displayed.compactMap { $0.tvShowId }
    XCTAssertEqual(showIds.count, displayed.count, "所有代表的 tvShowId 必须非 nil")
    XCTAssertEqual(Set(showIds).count, showIds.count, "代表的 tvShowId 必须唯一（每剧一张）")
    XCTAssertTrue(Set(showIds) == Set(["剧A", "剧B"]),
                  "代表的 tvShowId 集合必须 == {剧A, 剧B}")

    // 契约 2：displayedGroupCounts 同序同长
    let counts = vc.displayedGroupCounts
    XCTAssertEqual(counts.count, displayed.count,
                   "displayedGroupCounts 必须与 displayedItems 同长")
    // 剧A 应是 3，剧B 应是 2（按 displayedItems 同序）
    let byId = Dictionary(uniqueKeysWithValues: zip(showIds, counts))
    XCTAssertEqual(byId["剧A"], 3, "剧A 的 groupCount 必须 == 3")
    XCTAssertEqual(byId["剧B"], 2, "剧B 的 groupCount 必须 == 2")
  }

  // MARK: - 契约 3：电视剧分类搜索匹配剧名

  /// 谓词：电视剧分类 + filter="剧A" → displayedItems 仅含剧A 代表（1 张）
  func test_tvShow_category_filter_matches_show_name() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let a1 = makeEpisode(showId: "剧A", epNum: 1, cleanedName: "剧A",
                         urlPath: "/tmp/iina_redteam_vc_filter_A.mkv")
    let b1 = makeEpisode(showId: "剧B", epNum: 1, cleanedName: "剧B",
                         urlPath: "/tmp/iina_redteam_vc_filter_B.mkv")
    MediaLibraryStore.shared.setItemsForTesting([a1, b1])

    vc.currentCategory = .tvShow
    vc.currentFilter = "剧A"
    vc.refresh()

    XCTAssertEqual(vc.displayedItems.count, 1, "filter=剧A 必须仅 1 个代表")
    XCTAssertEqual(vc.displayedItems.first?.tvShowId, "剧A",
                   "搜索后代表必须是剧A")
  }

  /// 谓词：电视剧分类 + filter=空 → 全部剧代表
  func test_tvShow_category_empty_filter_shows_all_shows() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let a1 = makeEpisode(showId: "剧A", epNum: 1, cleanedName: "剧A",
                         urlPath: "/tmp/iina_redteam_vc_emptyfilter_A.mkv")
    let b1 = makeEpisode(showId: "剧B", epNum: 1, cleanedName: "剧B",
                         urlPath: "/tmp/iina_redteam_vc_emptyfilter_B.mkv")
    MediaLibraryStore.shared.setItemsForTesting([a1, b1])

    vc.currentCategory = .tvShow
    vc.currentFilter = ""
    vc.refresh()

    XCTAssertEqual(vc.displayedItems.count, 2, "空 filter 必须全部剧代表（2）")
  }

  // MARK: - 契约 4：非电视剧分类 → 旧行为，displayedGroupCounts 空

  /// 谓词：电影分类 → displayedItems 为全部电影，displayedGroupCounts 为空
  func test_movie_category_legacy_behavior_empty_group_counts() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let m1 = makeMovie(cleanedName: "电影1", urlPath: "/tmp/iina_redteam_vc_m1.mkv")
    let m2 = makeMovie(cleanedName: "电影2", urlPath: "/tmp/iina_redteam_vc_m2.mkv")
    // 也注入电视剧，验证电影分类不受电视剧影响
    let tv1 = makeEpisode(showId: "剧X", epNum: 1, cleanedName: "剧X",
                          urlPath: "/tmp/iina_redteam_vc_tv1.mkv")
    MediaLibraryStore.shared.setItemsForTesting([m1, m2, tv1])

    vc.currentCategory = .movie
    vc.currentFilter = ""
    vc.refresh()

    XCTAssertEqual(vc.displayedItems.count, 2, "电影分类必须显示 2 部电影（非电视剧）")
    XCTAssertEqual(Set(vc.displayedItems.map(\.cleanedName)), Set(["电影1", "电影2"]),
                   "电影分类 displayedItems 必须只含电影")
    XCTAssertTrue(vc.displayedGroupCounts.isEmpty,
                  "非电视剧分类的 displayedGroupCounts 必须为空数组（旧行为）")
  }

  // MARK: - 契约 5：分类切换 → refresh 重算

  /// 谓词：切换 currentCategory → refresh() 后 displayedItems/displayedGroupCounts 反映新分类
  func test_category_switch_refreshes_displayedItems() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let m1 = makeMovie(cleanedName: "电影", urlPath: "/tmp/iina_redteam_vc_switch_m.mkv")
    let a1 = makeEpisode(showId: "剧A", epNum: 1, cleanedName: "剧A",
                         urlPath: "/tmp/iina_redteam_vc_switch_a.mkv")
    MediaLibraryStore.shared.setItemsForTesting([m1, a1])

    // 切到电影
    vc.currentCategory = .movie
    vc.refresh()
    XCTAssertEqual(vc.displayedItems.count, 1, "电影分类 1 项")
    XCTAssertTrue(vc.displayedGroupCounts.isEmpty, "电影分类 groupCounts 空")

    // 切到电视剧
    vc.currentCategory = .tvShow
    vc.refresh()
    XCTAssertEqual(vc.displayedItems.count, 1, "电视剧分类 1 代表")
    XCTAssertEqual(vc.displayedGroupCounts, [1], "电视剧分类 groupCounts == [1]")

    // 切回电影
    vc.currentCategory = .movie
    vc.refresh()
    XCTAssertEqual(vc.displayedItems.count, 1, "切回电影 1 项")
    XCTAssertTrue(vc.displayedGroupCounts.isEmpty, "切回电影 groupCounts 空")
  }

  // MARK: - 契约 6：continueWatchingHeightConstraint 动态值

  /// 谓词：无继续观看内容 → continueWatchingHeightConstraint.constant == 0
  func test_height_constraint_zero_when_no_continueWatching() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    // 空 store + 空 history → 无继续观看内容
    MediaLibraryStore.shared.setItemsForTesting([])
    vc.currentCategory = .movie
    vc.refresh()

    guard let constraint = vc.continueWatchingHeightConstraint else {
      XCTFail("continueWatchingHeightConstraint 必须存在（契约 §3 要求持有引用）"); return
    }
    XCTAssertEqual(constraint.constant, 0,
                   "无继续观看内容时 constant 必须 == 0（消除顶部 130pt 空白）")
  }

  /// 谓词：有继续观看内容 → continueWatchingHeightConstraint.constant == 130
  func test_height_constraint_130_when_has_continueWatching() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let movie = makeMovie(cleanedName: "进度电影", urlPath: "/tmp/iina_redteam_vc_cw_movie.mkv")
    injectHistoryEntry(url: movie.url, progressSeconds: 50, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([movie])

    vc.currentCategory = .movie
    vc.refresh()

    guard let constraint = vc.continueWatchingHeightConstraint else {
      XCTFail("continueWatchingHeightConstraint 必须存在"); return
    }
    XCTAssertEqual(constraint.constant, 130,
                   "有继续观看内容时 constant 必须 == 130")
  }

  /// 谓词：分类切换不改变 continueWatchingHeightConstraint 的正确性（continueWatching 跨分类）
  /// CONTRACT_AMBIGUOUS: 设计文档 §3「continueWatchingHeightConstraint.constant 反映
  ///   continueWatchingItems 是否为空」——continueWatchingItems 是全局查询（不分分类）。
  ///   即切到任意分类，constant 都应一致（取决于全局是否有进度项）。
  func test_height_constraint_consistent_across_categories() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let movie = makeMovie(cleanedName: "跨分类进度", urlPath: "/tmp/iina_redteam_vc_xcat.mkv")
    injectHistoryEntry(url: movie.url, progressSeconds: 50, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([movie])

    // 有进度项 → 所有分类下 constant 都应 == 130
    for cat in [MediaCategory.movie, .tvShow, .other] {
      vc.currentCategory = cat
      vc.refresh()
      XCTAssertEqual(vc.continueWatchingHeightConstraint?.constant, 130,
                     "分类 \(cat) 下 constant 必须 == 130（有全局进度项）")
    }

    // 清空 → 所有分类下 constant 都应 == 0
    cleanupInjectedHistory()
    MediaLibraryStore.shared.setItemsForTesting([])
    for cat in [MediaCategory.movie, .tvShow, .other] {
      vc.currentCategory = cat
      vc.refresh()
      XCTAssertEqual(vc.continueWatchingHeightConstraint?.constant, 0,
                     "分类 \(cat) 下 constant 必须 == 0（无进度项）")
    }
  }

  // MARK: - 契约 6 边界：历史更新 → refresh 重算 constant

  /// 谓词：运行中历史更新（用户看完一部）→ refresh() 后 constant 从 130 变 0
  func test_height_constraint_updates_after_history_change() {
    guard let vc = makeVC() else {
      XCTFail("无法实例化 VC — GUI_ACCEPTANCE"); return
    }
    let movie = makeMovie(cleanedName: "动态进度", urlPath: "/tmp/iina_redteam_vc_dyn.mkv")
    injectHistoryEntry(url: movie.url, progressSeconds: 50, played: false, addedDate: Date())
    MediaLibraryStore.shared.setItemsForTesting([movie])
    vc.currentCategory = .movie
    vc.refresh()
    XCTAssertEqual(vc.continueWatchingHeightConstraint?.constant, 130, "初始有进度 → 130")

    // 模拟用户看完：清空进度（或移除 history 条目）
    cleanupInjectedHistory()
    vc.refresh()  // 历史更新后须 refresh 重算
    XCTAssertEqual(vc.continueWatchingHeightConstraint?.constant, 0,
                   "历史清空后 refresh → constant 必须 == 0")
  }

  // MARK: - GUI_ACCEPTANCE: 顶部空白与卡片渲染（留 QA 真机判定）

  // GUI_ACCEPTANCE: 顶部空白像素测量
  //   无继续观看内容时切到电影/电视剧分类 → segmentedControl 贴近顶部，无 130pt 空白
  //   验证方式：启动 IINA → AX 树读 segmentedControl.frame.origin.y vs window.top
  //   预期：origin.y < 20pt（贴近顶部），非 ~138pt
  //   留 QA 真机判定（marker/截图）—— 见 MediaLibraryUIVisualResidue.acceptance.test.swift 风格
  //
  // GUI_ACCEPTANCE: 剧集集合卡片角标「N集」实际可见
  //   电视剧分类 → 每张卡片左上角显示「N集」角标（圆角半透明背景白字）
  //   验证方式：AX 树或截图 → 卡片存在含「N集」文本的子元素
  //   留 QA 真机判定
  //
  // GUI_ACCEPTANCE: 点击剧集集合卡片导航
  //   点击代表卡片 → EpisodeListViewController sheet 弹出 → 显示该剧全部单集
  //   （导航层零改动，复用既有 onSelectTVShow → showEpisodeList(for:)）
  //   留 QA 真机判定
}
