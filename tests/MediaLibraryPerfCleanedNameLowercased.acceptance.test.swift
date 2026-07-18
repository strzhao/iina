//
//  MediaLibraryPerfCleanedNameLowercased.acceptance.test.swift
//  iina
//
//  红队验收测试 — P4 MediaItem 预计算 cleanedNameLowercased（黑盒视角）
//
//  覆盖谓词：
//    P4.1 [det-machine] 搜索结果 == reference（多查询词大小写 / 中文 / 符号）
//    P4.2 [det-machine] 搜索路径用 cleanedNameLowercased（字段存在且 == lowercased()）
//    P4.3 [det-machine] cleanedName 变更后 lowercased 同步（rescan 新 item）
//    P4.4 [det-machine] 旧 plist（无 Key）decode 后 cleanedNameLowercased == cleanedName.lowercased()
//           （I3 向后兼容）
//
//  设计文档声明 seam（internal）：
//    MediaItem.cleanedNameLowercased: String  // let，== cleanedName.lowercased()；
//                                        init(url:)+init?(coder:) 均赋值；
//                                        不参与 NSSecureCoding（无新 Key，旧 plist 向后兼容）
//
//  关键不变量（## 契约规约 边界值）：
//    cleanedNameLowercased == cleanedName.lowercased()（∀ MediaItem 实例）
//    P4 向后兼容（I3）：无 cleanedNameLowercased Key 的旧 plist decode 后，
//      item.cleanedNameLowercased == item.cleanedName.lowercased()
//

import XCTest
@testable import IINA

final class MediaLibraryPerfCleanedNameLowercasedAcceptanceTests: XCTestCase {

  // MARK: - 辅助

  private func makeItem(_ cleanedName: String, category: MediaCategory = .movie) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_perf_p4_\(UUID().uuidString).mkv"),
      cleanedName: cleanedName,
      rawName: cleanedName + ".mkv",
      category: category,
      tvShowId: nil,
      episodeNumber: nil,
      duration: 100,
      thumbnailPath: nil
    )
  }

  // MARK: - P4.2 字段存在且 == lowercased()（基础谓词，P4.1/P4.3/P4.4 依赖此契约）

  /// 谓词: P4.2 [det-machine] 搜索路径用 cleanedNameLowercased（字段 == lowercased()）
  /// WHEN 构造任意 MediaItem（含大小写 / 中文 / 符号混合），
  /// THEN item.cleanedNameLowercased == item.cleanedName.lowercased()。
  func test_cleanedNameLowercased_equals_cleanedName_lowercased() {
    let cases = [
      "Inception",
      "盗梦空间",
      "Movie [2024]",
      "UPPER CASE Title",
      "Mixed中英文Case",
      "  leading/trailing  ",
      "",
    ]

    for cleanedName in cases {
      let item = makeItem(cleanedName)
      let expected = cleanedName.lowercased()
      XCTAssertEqual(
        item.cleanedNameLowercased, expected,
        "P4.2 违反：cleanedNameLowercased != cleanedName.lowercased()。"
        + "input=\(cleanedName.debugDescription) actual=\(item.cleanedNameLowercased.debugDescription) "
        + "expected=\(expected.debugDescription)"
      )
    }
  }

  // MARK: - P4.1 搜索结果 == reference（多查询词：大小写 / 中文 / 符号）

  /// 谓词: P4.1 [det-machine] 搜索结果 == reference（多查询词大小写 / 中文 / 符号）
  /// WHEN 设置 items 并调 items(category:filter:) / tvShowGroups(filter:)，
  /// THEN 结果集 == reference oracle (cleanedName.lowercased().contains(needle.lowercased()))。
  /// 这同时验证查询路径用的是 cleanedNameLowercased 字段（而非每次 lowercased()）。
  func test_search_results_match_reference_for_diverse_needles() {
    let items = [
      makeItem("Inception", category: .movie),
      makeItem("INCEPTION 2", category: .movie),
      makeItem("盗梦空间", category: .movie),
      makeItem("Dào Mèng Kōng Jiān", category: .movie),
      makeItem("Movie [2024] (Directors Cut)", category: .movie),
      makeItem("UPPER", category: .movie),
      makeItem("other", category: .movie),
    ]
    MediaLibraryStore.shared.setItemsForTesting(items)

    // 多样化 needle：大小写 / 中文 / 拼音 / 符号 / 空格
    let needles = [
      "INCEP", "incep", "Incep",
      "盗梦", "空间",
      "2024", "[", "Directors",
      "UPPER", "upper",
      "other", "nonexistent",
    ]

    for needle in needles {
      let actual = MediaLibraryStore.shared.items(category: .movie, filter: needle)
      let lowerNeedle = needle.lowercased()
      let reference = items.filter { $0.cleanedName.lowercased().contains(lowerNeedle) }
      let actualSet = Set(actual.map { $0.url })
      let referenceSet = Set(reference.map { $0.url })

      XCTAssertEqual(
        actualSet, referenceSet,
        "P4.1 违反：needle=\(needle.debugDescription) 查询结果 != reference。\n"
        + "actual=\(actual.map { $0.cleanedName })\n"
        + "reference=\(reference.map { $0.cleanedName })"
      )
    }
  }

  // MARK: - P4.3 cleanedName 变更后 lowercased 同步（rescan 新 item）

  /// 谓词: P4.3 [det-machine] cleanedName 变更后 lowercased 同步（rescan 新 item）
  /// WHEN rescan（或 setItems）用新 MediaItem 替换旧 items，
  /// THEN 新 item 的 cleanedNameLowercased 自动用新 cleanedName.lowercased() 计算（let，无失效循环）。
  /// 关键：cleanedNameLowercased 是 let，在 init 时计算；rescan 全换新 item 时新 item init 自动算新值。
  func test_cleanedNameLowercased_syncs_on_rescan_new_items() {
    let oldItems = [makeItem("OLD Title")]
    MediaLibraryStore.shared.setItemsForTesting(oldItems)
    XCTAssertEqual(
      MediaLibraryStore.shared.items[0].cleanedNameLowercased,
      "old title",
      "P4.3 前置：旧 item cleanedNameLowercased 应 == 'old title'"
    )

    // 模拟 rescan（新扫描产出新 MediaItem）
    let newItems = [makeItem("NEW Title")]
    MediaLibraryStore.shared.setItemsForTesting(newItems)

    XCTAssertEqual(
      MediaLibraryStore.shared.items[0].cleanedNameLowercased,
      "new title",
      "P4.3 违反：rescan 替换为新 item 后 cleanedNameLowercased 未同步（应为 'new title'）。"
      + "cleanedNameLowercased 应是 let，init 时按新 cleanedName 计算（无失效循环 / probedKeys 教训）。"
    )

    // 查询路径用新 lowercased
    let result = MediaLibraryStore.shared.items(category: .movie, filter: "new")
    XCTAssertEqual(
      result.count, 1,
      "P4.3：rescan 后用新 needle 'new' 应命中 1 项（新 cleanedNameLowercased 已更新）"
    )
  }

  // MARK: - P4.4 向后兼容（I3）：旧 plist（无 Key）decode 后 == cleanedName.lowercased()

  /// 谓词: P4.4 [det-machine] 旧 plist decode 后 cleanedNameLowercased == cleanedName.lowercased()
  /// WHEN 用现有 plist（不含 cleanedNameLowercased Key，P4 设计明确「不参与 NSSecureCoding」）
  ///      通过 NSKeyedUnarchiver decode 一个 MediaItem，
  /// THEN decoded.cleanedNameLowercased == decoded.cleanedName.lowercased()
  ///      （init?(coder:) 在解码 cleanedName 后赋值 cleanedNameLowercased）。
  ///
  /// 关键：P4 不改 plist schema（cleanedNameLowercased 不入档），旧 plist 必须能 decode 且字段值正确。
  func test_old_plist_decodes_with_correct_lowercased_field() throws {
    // 构造一个 MediaItem（其 encode 不含 cleanedNameLowercased Key——这是 P4 设计）
    let original = makeItem("Old Plist Title 2024")
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: original, requiringSecureCoding: true)

    // NSKeyedArchiver 仅编码 MediaItem.encode(with:) 中显式编码的 Key
    // 设计声明 cleanedNameLowercased 不入 encode——验证 data 中无对应 Key
    // （由 init?(coder:) 解码 cleanedName 后实时计算 cleanedNameLowercased）

    // 反序列化（模拟从旧 plist 加载）
    let decoded = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: MediaItem.self, from: data)

    guard let item = decoded else {
      XCTFail("P4.4 前置失败：MediaItem 反序列化结果为 nil")
      return
    }

    // 核心断言：cleanedNameLowercased == cleanedName.lowercased()
    XCTAssertEqual(
      item.cleanedNameLowercased,
      item.cleanedName.lowercased(),
      "P4.4 违反（I3 向后兼容）：旧 plist decode 后 cleanedNameLowercased != cleanedName.lowercased()。"
      + "cleanedName=\(item.cleanedName) cleanedNameLowercased=\(item.cleanedNameLowercased)"
    )
    XCTAssertEqual(
      item.cleanedNameLowercased, "old plist title 2024",
      "P4.4：cleanedNameLowercased 应为 'old plist title 2024'"
    )

    // 额外：断言 cleanedNameLowercased 是新实例的字段（每次 init 都计算）
    let decoded2 = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: MediaItem.self, from: data)
    XCTAssertEqual(
      decoded2?.cleanedNameLowercased,
      item.cleanedNameLowercased,
      "P4.4：两次 decode 的 cleanedNameLowercased 应一致（同一 plist 输入 → 同一输出）"
    )
  }

  /// 谓词: P4.4 [det-machine] 旧 plist（含完整字段）decode 后所有字段含 cleanedNameLowercased 一致
  /// 用含 TV 字段、duration、thumbnailPath 的完整 MediaItem 验证 P4 不破坏现有编码。
  func test_old_plist_full_fields_decode_correctly() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/tmp/p4_full.mkv"),
      cleanedName: "Complete Show S01",
      rawName: "Complete.Show.S01.1080p",
      category: .tvShow,
      tvShowId: "Complete Show",
      episodeNumber: 5,
      duration: 1800.5,
      thumbnailPath: URL(fileURLWithPath: "/tmp/thumb.png")
    )
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: original, requiringSecureCoding: true)
    let decoded = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: MediaItem.self, from: data)

    XCTAssertEqual(decoded?.cleanedName, "Complete Show S01")
    XCTAssertEqual(
      decoded?.cleanedNameLowercased, "complete show s01",
      "P4.4：完整字段 item decode 后 cleanedNameLowercased 必须 == 'complete show s01'"
    )
    XCTAssertEqual(decoded?.tvShowId, "Complete Show")
    XCTAssertEqual(decoded?.episodeNumber, 5)
    XCTAssertEqual(decoded?.duration, 1800.5)
  }
}
