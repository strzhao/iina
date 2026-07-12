//
//  TVShowGroups.acceptance.test.swift
//  iina
//
//  红队验收测试 — 剧集集合数据层契约（黑盒视角，基于设计文档 ## 契约规约 §1）
//
//  覆盖契约点（逐条硬断言）：
//    1. 分组数量：每个 tvShowIndex key 恰好一个 TVShowGroup
//    2. representative.tvShowId == key（一致性）
//    3. episodeCount == tvShowIndex[key].count ≥ 1
//    4. 代表选取：lastWatchedEpisode(tvShowId:) 命中 → 用之；否则 episodes.first（首集，episodeNumber 最小者）
//    5. filter：nil/空串 → 全量；非空 → case-insensitive contains 匹配 representative.cleanedName
//    6. 排序：按 representative.cleanedName 升序（确定性）
//    7. 线程/不可变性：tvShowGroups 不修改 tvShowIndex / items（状态幂等）
//
//  验收场景（设计文档 ## 验证方案 纯逻辑验证）：
//    构造 3 剧：
//      A「剧A」: ep1-3（无 lastWatched）→ 代表 A.ep1，count 3
//      B「剧B」: ep1-2（lastWatched=ep2）→ 代表 B.ep2，count 2
//      C「剧C」: ep1（episodeNumber=nil）→ 代表 C.ep1，count 1
//    断言：tvShowGroups 返回 3 组，代表与 counts 正确；filter="b"（case-insensitive）→ 仅 B 组；按 cleanedName 升序
//

import XCTest
@testable import iina

final class TVShowGroupsAcceptanceTests: XCTestCase {

  // MARK: - 辅助夹具

  /// 视频时长（秒），契约 example 用 100s
  private let durationSeconds: Double = 100.0

  /// 构造一个电视剧单集 MediaItem
  /// - Parameters:
  ///   - showId: tvShowId（剧集分组键，也是 collection 卡片标题来源）
  ///   - epNum: episodeNumber；nil 表示散文件（仍归属该剧）
  ///   - cleanedName: 清洗后的展示名（影响 filter 与排序）
  ///   - suffix: url 后缀，保证唯一
  private func makeEpisode(showId: String,
                            epNum: Int?,
                            cleanedName: String,
                            urlPath: String) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: urlPath),
      cleanedName: cleanedName,
      rawName: cleanedName + ".1080p",
      category: .tvShow,
      tvShowId: showId,
      episodeNumber: epNum,
      duration: durationSeconds,
      thumbnailPath: nil
    )
  }

  /// 构造带进度的 PlaybackHistory 并注入 HistoryController.shared.history
  /// - Parameters:
  ///   - url: 关联的 MediaItem.url
  ///   - progressSeconds: mpvProgress 秒数
  ///   - played: 是否已标记 played
  ///   - addedDate: 记录时间（影响 lastWatchedEpisode 的"最近"判定）
  private func injectHistoryEntry(url: URL, progressSeconds: Double, played: Bool, addedDate: Date) {
    // CONTRACT: Store.continueWatchingItems / lastWatchedEpisode 通过
    // Utility.mpvWatchLaterMd5(url, ignorePath=false) 关联 history.mpvMd5。
    // 与既有 MediaLibraryStore.acceptance.test.swift 的夹具一致（ignorePath=false）。
    let durationVT = VideoTime(durationSeconds)
    let progressVT = VideoTime(progressSeconds)
    let mpvMd5 = Utility.mpvWatchLaterMd5(url, false)
    let entry = PlaybackHistory(
      url: url,
      name: url.lastPathComponent,
      mpvMd5: mpvMd5,
      played: played,
      addedDate: addedDate,
      duration: durationVT,
      mpvProgress: progressVT,
      title: nil
    )
    HistoryController.shared.history.append(entry)
  }

  /// 清理：移除本测试注入的 history 条目（按 url 前缀识别）
  private func cleanupInjectedHistory(prefix: String = "/tmp/iina_redteam_tvgroups_") {
    HistoryController.shared.history.removeAll { $0.url.path.hasPrefix(prefix) }
  }

  override func tearDown() {
    cleanupInjectedHistory()
    super.tearDown()
  }

  // MARK: - 契约 1+2+3+4：分组数量 / tvShowId 一致性 / episodeCount / 代表选取（综合验收场景）

  /// 谓词（验收场景 A+B+C）：3 剧 → 3 组，代表与 episodeCount 与契约逐条一致
  ///   A「剧A」: ep1-3（无 lastWatched）→ 代表 A.ep1（episodeNumber 最小），count 3
  ///   B「剧B」: ep1-2（lastWatched=ep2）→ 代表 B.ep2，count 2
  ///   C「剧C」: ep1（episodeNumber=nil）→ 代表 C.ep1，count 1
  func test_tvShowGroups_three_shows_representative_and_count() {
    // --- 构造 3 剧单集 ---
    let showA = "剧A"
    let showB = "剧B"
    let showC = "剧C"

    // A: ep1-3，episodeNumber 乱序注入以验证排序（rebuildIndices 应按 ep 升序）
    let a_ep3 = makeEpisode(showId: showA, epNum: 3, cleanedName: "剧A",
                             urlPath: "/tmp/iina_redteam_tvgroups_A_ep3.mkv")
    let a_ep1 = makeEpisode(showId: showA, epNum: 1, cleanedName: "剧A",
                             urlPath: "/tmp/iina_redteam_tvgroups_A_ep1.mkv")
    let a_ep2 = makeEpisode(showId: showA, epNum: 2, cleanedName: "剧A",
                             urlPath: "/tmp/iina_redteam_tvgroups_A_ep2.mkv")
    // B: ep1-2
    let b_ep1 = makeEpisode(showId: showB, epNum: 1, cleanedName: "剧B",
                             urlPath: "/tmp/iina_redteam_tvgroups_B_ep1.mkv")
    let b_ep2 = makeEpisode(showId: showB, epNum: 2, cleanedName: "剧B",
                             urlPath: "/tmp/iina_redteam_tvgroups_B_ep2.mkv")
    // C: ep1（episodeNumber=nil）
    let c_ep1 = makeEpisode(showId: showC, epNum: nil, cleanedName: "剧C",
                             urlPath: "/tmp/iina_redteam_tvgroups_C_ep1.mkv")

    // 注入 B.ep2 的观看进度 → B 的 lastWatchedEpisode 命中
    injectHistoryEntry(url: b_ep2.url, progressSeconds: 30, played: false,
                       addedDate: Date().addingTimeInterval(100))

    // 注入到 Store（夹具 helper，蓝队须提供；语义等价于 setItems）
    // CONTRACT_NOTE: 与既有 MediaLibraryStore.acceptance.test.swift 同一夹具约定。
    MediaLibraryStore.shared.setItemsForTesting([a_ep3, a_ep1, a_ep2, b_ep1, b_ep2, c_ep1])

    let groups = MediaLibraryStore.shared.tvShowGroups(filter: nil)

    // 契约 1：分组数量 == tvShowIndex key 数量（3）
    XCTAssertEqual(groups.count, 3,
                   "3 个 tvShowId 必须恰好 3 组，实际: \(groups.count)")

    // 按 cleanedName 建立查找（便于断言，不依赖返回顺序——顺序由契约 6 单独验证）
    var byShow: [String: TVShowGroup] = [:]
    for g in groups {
      // 契约 2：representative.tvShowId == key
      XCTAssertNotNil(g.representative.tvShowId,
                      "代表 MediaItem 的 tvShowId 不得为 nil")
      byShow[g.representative.tvShowId ?? ""] = g
    }

    // --- 契约 3+4 验收场景 A：代表 = A.ep1（首集，episodeNumber 最小），count = 3 ---
    guard let groupA = byShow[showA] else {
      XCTFail("缺少剧A 的 group"); return
    }
    XCTAssertEqual(groupA.episodeCount, 3, "剧A 的 episodeCount 必须 == 3")
    XCTAssertEqual(groupA.representative.url, a_ep1.url,
                   "剧A 无 lastWatched → 代表必须是首集 A.ep1（episodeNumber 最小者）")
    XCTAssertEqual(groupA.representative.episodeNumber, 1,
                   "剧A 代表的 episodeNumber 必须 == 1（首集）")

    // --- 契约 3+4 验收场景 B：代表 = B.ep2（lastWatched 命中），count = 2 ---
    guard let groupB = byShow[showB] else {
      XCTFail("缺少剧B 的 group"); return
    }
    XCTAssertEqual(groupB.episodeCount, 2, "剧B 的 episodeCount 必须 == 2")
    XCTAssertEqual(groupB.representative.url, b_ep2.url,
                   "剧B lastWatched 命中 → 代表必须是 B.ep2（非首集）")
    XCTAssertEqual(groupB.representative.episodeNumber, 2,
                   "剧B 代表的 episodeNumber 必须 == 2（lastWatched 集数）")

    // --- 契约 3+4 验收场景 C：代表 = C.ep1（episodeNumber=nil 仍取 first），count = 1 ---
    guard let groupC = byShow[showC] else {
      XCTFail("缺少剧C 的 group"); return
    }
    XCTAssertEqual(groupC.episodeCount, 1, "剧C 的 episodeCount 必须 == 1")
    XCTAssertEqual(groupC.representative.url, c_ep1.url,
                   "剧C 仅 1 集（episodeNumber=nil）→ 代表必须是 C.ep1")
    XCTAssertNil(groupC.representative.episodeNumber,
                 "剧C 代表的 episodeNumber 必须保持 nil（散文件）")
  }

  // MARK: - 契约 5：filter（nil / 空串 / case-insensitive contains）

  /// 谓词：filter=nil → 全量返回（与无 filter 一致）
  func test_tvShowGroups_filter_nil_returns_all() {
    let showX = "剧X"
    let showY = "剧Y"
    let x1 = makeEpisode(showId: showX, epNum: 1, cleanedName: "剧X",
                          urlPath: "/tmp/iina_redteam_tvgroups_filter_X.mkv")
    let y1 = makeEpisode(showId: showY, epNum: 1, cleanedName: "剧Y",
                          urlPath: "/tmp/iina_redteam_tvgroups_filter_Y.mkv")
    MediaLibraryStore.shared.setItemsForTesting([x1, y1])

    let groups = MediaLibraryStore.shared.tvShowGroups(filter: nil)
    XCTAssertEqual(groups.count, 2, "filter=nil 必须 2 组（全量）")
  }

  /// 谓词：filter="" → 全量（与 nil 同义）
  func test_tvShowGroups_filter_empty_string_returns_all() {
    let showX = "剧X"
    let showY = "剧Y"
    let x1 = makeEpisode(showId: showX, epNum: 1, cleanedName: "剧X",
                          urlPath: "/tmp/iina_redteam_tvgroups_empty_X.mkv")
    let y1 = makeEpisode(showId: showY, epNum: 1, cleanedName: "剧Y",
                          urlPath: "/tmp/iina_redteam_tvgroups_empty_Y.mkv")
    MediaLibraryStore.shared.setItemsForTesting([x1, y1])

    let groups = MediaLibraryStore.shared.tvShowGroups(filter: "")
    XCTAssertEqual(groups.count, 2, "filter=空串必须 2 组（等价 nil）")
  }

  /// 谓词（验收场景 filter="b"）：case-insensitive contains → 仅匹配剧
  /// 构造「剧B」(cleanedName="剧B") + 「剧A」(cleanedName="剧A")，
  /// filter="b" 必须命中「剧B」——证明大小写不敏感且以 representative.cleanedName 匹配。
  /// 此处用 ASCII 名便于验证 case-insensitive（"Bravo" vs filter "b" / "B"）
  func test_tvShowGroups_filter_case_insensitive_contains() {
    let showBravo = "Bravo"
    let showAlpha = "Alpha"
    let b1 = makeEpisode(showId: showBravo, epNum: 1, cleanedName: "Bravo",
                          urlPath: "/tmp/iina_redteam_tvgroups_ci_B.mkv")
    let a1 = makeEpisode(showId: showAlpha, epNum: 1, cleanedName: "Alpha",
                          urlPath: "/tmp/iina_redteam_tvgroups_ci_A.mkv")
    MediaLibraryStore.shared.setItemsForTesting([b1, a1])

    // 小写 "b" 必须命中 cleanedName="Bravo"（大写 B）
    let lower = MediaLibraryStore.shared.tvShowGroups(filter: "b")
    XCTAssertEqual(lower.count, 1, "filter=\"b\"（小写）必须仅命中 Bravo（case-insensitive）")
    XCTAssertEqual(lower.first?.representative.cleanedName, "Bravo",
                   "filter=\"b\" 命中的代表 cleanedName 必须 == \"Bravo\"")

    // 大写 "B" 也必须命中同一组（双向 case-insensitive）
    let upper = MediaLibraryStore.shared.tvShowGroups(filter: "B")
    XCTAssertEqual(upper.count, 1, "filter=\"B\"（大写）必须仅命中 Bravo")
    XCTAssertEqual(upper.first?.representative.cleanedName, "Bravo")

    // 不匹配任何组的 filter → 空
    let none = MediaLibraryStore.shared.tvShowGroups(filter: "zzz")
    XCTAssertTrue(none.isEmpty, "filter=\"zzz\" 不得命中任何组")
  }

  /// 谓词：filter 必须匹配 representative.cleanedName（而非 tvShowId）。
  /// 构造一个 tvShowId 与 cleanedName 不一致的剧，验证 filter 走的是 cleanedName。
  /// CONTRACT_AMBIGUOUS: 设计文档 §1「filter 匹配 representative.cleanedName」明确，
  ///   但 representative 可能因 lastWatched 切换为不同集（不同 cleanedName）。
  ///   若代表 cleanedName 不含剧名（如代表是 ep3，cleanedName="剧A 第3集"），
  ///   filter="剧A" 是否命中取决于 cleanedName 是否含子串。本测试只验证"匹配代表 cleanedName"
  ///   这条契约本身，不假设 cleanedName 与 tvShowId 一致。
  func test_tvShowGroups_filter_matches_representative_cleanedName_not_showId() {
    // tvShowId="剧X"，但代表 cleanedName="SpecialFeature"（无"剧X"子串）
    let x1 = makeEpisode(showId: "剧X", epNum: 1, cleanedName: "SpecialFeature",
                          urlPath: "/tmp/iina_redteam_tvgroups_matchname.mkv")
    MediaLibraryStore.shared.setItemsForTesting([x1])

    // filter="剧X"（tvShowId）→ 不应命中（cleanedName 不含"剧X"）
    let byShowId = MediaLibraryStore.shared.tvShowGroups(filter: "剧X")
    XCTAssertTrue(byShowId.isEmpty,
                 "filter 必须匹配 representative.cleanedName，而非 tvShowId；"
                 + "cleanedName=\"SpecialFeature\" 不含 \"剧X\" → 必须空")

    // filter="special"（cleanedName 子串，case-insensitive）→ 命中
    let byName = MediaLibraryStore.shared.tvShowGroups(filter: "special")
    XCTAssertEqual(byName.count, 1, "filter=\"special\" 必须命中（cleanedName 子串匹配）")
  }

  // MARK: - 契约 6：按 representative.cleanedName 升序（确定性）

  /// 谓词（验收场景排序）：3 剧按 cleanedName 升序（"剧A" < "剧B" < "剧C"）
  func test_tvShowGroups_sorted_by_cleanedName_ascending() {
    // 故意乱序注入，验证返回顺序与注入无关
    let c1 = makeEpisode(showId: "剧C", epNum: 1, cleanedName: "剧C",
                          urlPath: "/tmp/iina_redteam_tvgroups_sort_C.mkv")
    let a1 = makeEpisode(showId: "剧A", epNum: 1, cleanedName: "剧A",
                          urlPath: "/tmp/iina_redteam_tvgroups_sort_A.mkv")
    let b1 = makeEpisode(showId: "剧B", epNum: 1, cleanedName: "剧B",
                          urlPath: "/tmp/iina_redteam_tvgroups_sort_B.mkv")
    MediaLibraryStore.shared.setItemsForTesting([c1, a1, b1])

    let groups = MediaLibraryStore.shared.tvShowGroups(filter: nil)
    XCTAssertEqual(groups.count, 3, "应有 3 组")

    // 升序断言（逐对比较）
    XCTAssertEqual(groups[0].representative.cleanedName, "剧A",
                   "升序第 1 必须是「剧A」")
    XCTAssertEqual(groups[1].representative.cleanedName, "剧B",
                   "升序第 2 必须是「剧B」")
    XCTAssertEqual(groups[2].representative.cleanedName, "剧C",
                   "升序第 3 必须是「剧C」")

    // 通用升序不变量：∀ 相邻对，前者 cleanedName ≤ 后者
    for i in 0..<(groups.count - 1) {
      XCTAssertLessThanOrEqual(groups[i].representative.cleanedName,
                               groups[i + 1].representative.cleanedName,
                               "相邻对必须非递减（升序），索引 \(i) 违反")
    }
  }

  /// 谓词：filter 后的结果仍按 cleanedName 升序
  func test_tvShowGroups_filter_result_still_sorted() {
    let items = (0..<5).map { i in
      makeEpisode(showId: "剧\(i)", epNum: 1, cleanedName: "剧\(i)",
                  urlPath: "/tmp/iina_redteam_tvgroups_fsort_\(i).mkv")
    }
    MediaLibraryStore.shared.setItemsForTesting(items)

    // filter 命中多个（"剧" 是公共子串）
    let groups = MediaLibraryStore.shared.tvShowGroups(filter: "剧")
    XCTAssertEqual(groups.count, 5, "filter=\"剧\" 必须 5 组全命中")
    for i in 0..<(groups.count - 1) {
      XCTAssertLessThanOrEqual(groups[i].representative.cleanedName,
                               groups[i + 1].representative.cleanedName,
                               "filter 后仍须升序，索引 \(i) 违反")
    }
  }

  // MARK: - 契约 4 边界：lastWatchedEpisode 多集有进度 → 取最近 addedDate

  /// 谓词：同一剧多集有进度时，代表 = addedDate 最大的那集（lastWatched 语义）
  func test_tvShowGroups_representative_is_most_recent_lastWatched() {
    let show = "多进度剧"
    let ep1 = makeEpisode(showId: show, epNum: 1, cleanedName: show,
                           urlPath: "/tmp/iina_redteam_tvgroups_multi_ep1.mkv")
    let ep2 = makeEpisode(showId: show, epNum: 2, cleanedName: show,
                           urlPath: "/tmp/iina_redteam_tvgroups_multi_ep2.mkv")
    let ep3 = makeEpisode(showId: show, epNum: 3, cleanedName: show,
                           urlPath: "/tmp/iina_redteam_tvgroups_multi_ep3.mkv")

    // ep2 的 addedDate 比 ep3 旧 → lastWatched 应是 ep3
    injectHistoryEntry(url: ep2.url, progressSeconds: 10, played: false,
                       addedDate: Date().addingTimeInterval(-1000))
    injectHistoryEntry(url: ep3.url, progressSeconds: 20, played: false,
                       addedDate: Date())  // 最新

    MediaLibraryStore.shared.setItemsForTesting([ep1, ep2, ep3])

    let groups = MediaLibraryStore.shared.tvShowGroups(filter: nil)
    XCTAssertEqual(groups.count, 1, "单剧单组")
    XCTAssertEqual(groups.first?.representative.url, ep3.url,
                   "lastWatched 必须取 addedDate 最大的 ep3")
    XCTAssertEqual(groups.first?.episodeCount, 3, "episodeCount 必须 == 3")
  }

  // MARK: - 契约 7：不可变性（tvShowGroups 不修改 tvShowIndex / items）

  /// 谓词：连续两次调用 tvShowGroups 结果一致（幂等），且不影响后续 lastWatchedEpisode / tvShowEpisodes
  func test_tvShowGroups_does_not_mutate_state() {
    let show = "幂等剧"
    let ep1 = makeEpisode(showId: show, epNum: 1, cleanedName: show,
                           urlPath: "/tmp/iina_redteam_tvgroups_idem_ep1.mkv")
    let ep2 = makeEpisode(showId: show, epNum: 2, cleanedName: show,
                           urlPath: "/tmp/iina_redteam_tvgroups_idem_ep2.mkv")
    MediaLibraryStore.shared.setItemsForTesting([ep1, ep2])

    let first = MediaLibraryStore.shared.tvShowGroups(filter: nil)
    let second = MediaLibraryStore.shared.tvShowGroups(filter: nil)

    XCTAssertEqual(first.count, second.count, "两次调用 count 必须一致（幂等）")
    XCTAssertEqual(first.first?.representative.url, second.first?.representative.url,
                   "两次调用代表必须一致（幂等）")
    XCTAssertEqual(first.first?.episodeCount, second.first?.episodeCount,
                   "两次调用 episodeCount 必须一致（幂等）")

    // tvShowEpisodes 不受影响（仍按 episodeNumber 升序 2 集）
    let eps = MediaLibraryStore.shared.tvShowEpisodes(tvShowId: show)
    XCTAssertEqual(eps.count, 2, "tvShowGroups 不得修改 tvShowIndex，episodes 仍须 2 集")
    XCTAssertEqual(eps[0].episodeNumber, 1, "episodes 排序不受影响")
    XCTAssertEqual(eps[1].episodeNumber, 2)
  }

  // MARK: - 空态 / 反例

  /// 谓词：无任何电视剧（tvShowIndex 空）→ 返回空数组
  func test_tvShowGroups_empty_store_returns_empty() {
    MediaLibraryStore.shared.setItemsForTesting([])
    let groups = MediaLibraryStore.shared.tvShowGroups(filter: nil)
    XCTAssertTrue(groups.isEmpty, "无电视剧时 tvShowGroups 必须返回空数组")
  }

  /// 谓词：仅电影/其它（无 .tvShow）→ 返回空（tvShowIndex 不含电影）
  func test_tvShowGroups_only_movies_returns_empty() {
    let movie = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_redteam_tvgroups_movie.mkv"),
      cleanedName: "电影1", rawName: "电影1.1080p", category: .movie,
      tvShowId: nil, episodeNumber: nil, duration: 100, thumbnailPath: nil
    )
    MediaLibraryStore.shared.setItemsForTesting([movie])
    let groups = MediaLibraryStore.shared.tvShowGroups(filter: nil)
    XCTAssertTrue(groups.isEmpty, "仅电影时 tvShowGroups 必须空（电影不入 tvShowIndex）")
  }

  // MARK: - TVShowGroup struct 字段契约（类型与字段名逐字一致）

  /// 谓词：TVShowGroup 暴露 representative: MediaItem 与 episodeCount: Int 字段
  /// 防止蓝队改名（如 rep/count）或改类型（如 Any/NSNumber）
  func test_TVShowGroup_struct_fields_contract() {
    let ep = makeEpisode(showId: "字段剧", epNum: 1, cleanedName: "字段剧",
                          urlPath: "/tmp/iina_redteam_tvgroups_fields.mkv")
    MediaLibraryStore.shared.setItemsForTesting([ep])

    guard let group = MediaLibraryStore.shared.tvShowGroups(filter: nil).first else {
      XCTFail("必须有 1 组才能验证字段"); return
    }
    // 字段名与类型逐字断言（编译期保证，此处再加运行期强断言）
    let _: MediaItem = group.representative          // 字段名 representative，类型 MediaItem
    let _: Int = group.episodeCount                  // 字段名 episodeCount，类型 Int
    XCTAssertEqual(group.episodeCount, 1, "episodeCount 字段值必须 == 1")
    XCTAssertEqual(group.representative.cleanedName, "字段剧",
                   "representative.cleanedName 必须保留原值")
  }
}
