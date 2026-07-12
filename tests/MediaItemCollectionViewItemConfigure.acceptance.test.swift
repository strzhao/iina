//
//  MediaItemCollectionViewItemConfigure.acceptance.test.swift
//  iina
//
//  红队验收测试 — 卡片层 configure 契约（黑盒视角，基于设计文档 ## 契约规约 §2）
//
//  覆盖契约点（逐条硬断言）：
//    1. 签名：configure(with item: MediaItem, ignorePath: Bool,
//                     displayName: String? = nil, episodeCount: Int? = nil)
//    2. displayName==nil → nameLabel 显示 item.cleanedName（旧行为，向后兼容）
//    3. displayName != nil → nameLabel 显示 displayName（覆盖）
//    4. episodeCount==nil → 不显示集数角标，progressIndicator 行为不变（旧行为）
//    5. episodeCount != nil → 显示「N集」角标，隐藏 progressIndicator 与 playedBadge
//    6. 幂等：同一 item 多次 configure 结果一致
//
//  说明：
//    MediaItemCollectionViewItem 是 NSCollectionViewItem 子类（Cocoa GUI），
//    其子视图（nameLabel/progressIndicator/playedBadge/episodeCountBadge）为 NSView。
//    XCTest 在 app 链接下可读这些 NSView 的 stringValue/isHidden 属性做强断言。
//    角标的「N集」文案格式（"3集"）属于契约显式声明，做字符串硬断言。
//

import XCTest
@testable import iina

final class MediaItemCollectionViewItemConfigureAcceptanceTests: XCTestCase {

  // MARK: - 夹具

  /// 构造一个电视剧代表 MediaItem（用于 configure）
  private func makeRepresentative(cleanedName: String = "代表剧",
                                   tvShowId: String? = "代表剧",
                                   epNum: Int? = 1) -> MediaItem {
    MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_redteam_card_\(UUID().uuidString).mkv"),
      cleanedName: cleanedName,
      rawName: cleanedName + ".1080p",
      category: .tvShow,
      tvShowId: tvShowId,
      episodeNumber: epNum,
      duration: 100.0,
      thumbnailPath: nil
    )
  }

  /// 创建并加载一个 MediaItemCollectionViewItem（view 必须完成 loadView 才能访问子视图）
  /// CONTRACT_NOTE: NSCollectionViewItem.viewDidLoad 会创建子视图；测试通过访问 .view 触发。
  private func makeLoadedItem() -> MediaItemCollectionViewItem {
    // CONTRACT_AMBIGUOUS: MediaItemCollectionViewItem 的构造入口（init(coder:) / init(nibName:bundle:)）
    //   取决于蓝队实现。若需 nib，测试环境可能加载失败。此处用最通用的 init(nibName:bundle:)
    //   降级为直接实例化，访问 .view 触发 loadView。若蓝队用 programmatic loadView，.view 访问即足够。
    let item = MediaItemCollectionViewItem(nibName: nil, bundle: nil)!
    _ = item.view  // 触发 viewDidLoad / loadView
    return item
  }

  // MARK: - 契约 1：签名兼容性（默认参数，向后兼容旧调用）

  /// 谓词：configure 必须接受仅 (with:, ignorePath:) 两参（默认参数 displayName/episodeCount）
  /// 旧调用方（ContinueWatchingView）不传 displayName/episodeCount 必须编译通过且运行不崩。
  /// 这是"向后兼容"的硬断言——若蓝队删除默认参数，此处编译失败。
  func test_configure_accepts_legacy_two_param_signature() {
    let item = makeLoadedItem()
    let media = makeRepresentative()

    // 仅传 (with:, ignorePath:) —— 默认参数生效，不得崩
    item.configure(with: media, ignorePath: false)

    // 契约 2 旁证：displayName==nil → nameLabel 显示 item.cleanedName（旧行为）
    XCTAssertEqual(item.nameLabel?.stringValue, media.cleanedName,
                   "displayName==nil 时 nameLabel 必须显示 item.cleanedName（旧行为）")
  }

  // MARK: - 契约 2：displayName==nil → nameLabel = item.cleanedName

  /// 谓词：displayName 省略（nil）→ nameLabel.stringValue == item.cleanedName
  func test_configure_displayName_nil_shows_cleanedName() {
    let item = makeLoadedItem()
    let media = makeRepresentative(cleanedName: "原片名ABC")

    item.configure(with: media, ignorePath: false)  // displayName 默认 nil

    XCTAssertEqual(item.nameLabel?.stringValue, "原片名ABC",
                   "displayName==nil → nameLabel 必须显示 cleanedName「原片名ABC」")
  }

  // MARK: - 契约 3：displayName != nil → nameLabel = displayName（覆盖 cleanedName）

  /// 谓词：displayName 显式传入 → nameLabel 显示 displayName，而非 cleanedName
  /// 应用场景：剧集集合卡片用 tvShowId（纯剧名）覆盖代表 cleanedName（可能含集数）
  func test_configure_displayName_non_nil_overrides_nameLabel() {
    let item = makeLoadedItem()
    // 代表 cleanedName 含集数（如"剧A 第3集"），但卡片标题应是纯剧名"剧A"
    let media = makeRepresentative(cleanedName: "剧A 第3集", tvShowId: "剧A", epNum: 3)

    item.configure(with: media, ignorePath: false, displayName: "剧A")

    XCTAssertEqual(item.nameLabel?.stringValue, "剧A",
                   "displayName=\"剧A\" 必须 覆盖 nameLabel，不得显示 cleanedName「剧A 第3集」")
    XCTAssertNotEqual(item.nameLabel?.stringValue, media.cleanedName,
                      "displayName 非 nil 时 nameLabel 不得等于 cleanedName（防退化）")
  }

  /// 谓词：displayName="" （空串非 nil）→ nameLabel 显示空串（contract：!= nil 即生效覆盖）
  /// CONTRACT_AMBIGUOUS: 设计文档未明确 displayName="" 是否当作 nil 处理。
  ///   严格按契约「displayName==nil → 旧行为」反推，空串非 nil 应覆盖为空。
  ///   此处断言覆盖语义，若蓝队把空串当 nil，本测试需调整（标 ambiguity）。
  func test_configure_displayName_empty_string_overrides() {
    let item = makeLoadedItem()
    let media = makeRepresentative(cleanedName: "不应显示")

    item.configure(with: media, ignorePath: false, displayName: "")

    XCTAssertEqual(item.nameLabel?.stringValue, "",
                   "displayName=\"\"（空串非 nil）必须覆盖 nameLabel 为空串")
  }

  // MARK: - 契约 4：episodeCount==nil → 不显示角标，progressIndicator 行为不变

  /// 谓词：episodeCount==nil → episodeCountBadge 不得可见（隐藏或不存在）
  func test_configure_episodeCount_nil_hides_badge() {
    let item = makeLoadedItem()
    let media = makeRepresentative()

    item.configure(with: media, ignorePath: false)  // episodeCount 默认 nil

    // CONTRACT_AMBIGUOUS: episodeCountBadge 的具体实现——蓝队可能用
    //   (a) 始终存在的 NSTextField，通过 isHidden 控制；
    //   (b) 按需 addSubview/removeFromSuperview。
    // 此处采用最稳健断言：若 badge 视图存在，则它必须 isHidden 或 stringValue 为空。
    if let badge = item.episodeCountBadge {
      XCTAssertTrue(badge.isHidden || (badge.stringValue.isEmpty),
                    "episodeCount==nil 时 episodeCountBadge 必须隐藏或为空")
    }
    // 若 episodeCountBadge 为 nil（实现 b），本断言自动通过——契约"不显示"已满足。
  }

  // MARK: - 契约 5：episodeCount != nil → 显示「N集」角标，隐藏 progressIndicator 与 playedBadge

  /// 谓词（核心）：episodeCount=3 → 角标文案含"3集"，且 progressIndicator 与 playedBadge 隐藏
  func test_configure_episodeCount_non_nil_shows_badge_and_hides_progress() {
    let item = makeLoadedItem()
    let media = makeRepresentative()

    item.configure(with: media, ignorePath: false, episodeCount: 3)

    // 角标存在且文案含"3集"
    guard let badge = item.episodeCountBadge else {
      XCTFail("episodeCount=3 时 episodeCountBadge 视图必须存在"); return
    }
    XCTAssertFalse(badge.isHidden,
                   "episodeCount != nil 时 episodeCountBadge 必须可见（!isHidden）")
    XCTAssertTrue(badge.stringValue.contains("3"),
                  "角标文案必须含集数「3」")
    XCTAssertTrue(badge.stringValue.contains("集"),
                  "角标文案必须含单位「集」")
    // 严格格式断言：合约显式「\(n)集」
    XCTAssertEqual(badge.stringValue, "3集",
                   "角标文案必须严格为「3集」")

    // progressIndicator 隐藏
    if let progress = item.progressIndicator {
      XCTAssertTrue(progress.isHidden,
                    "episodeCount != nil 时 progressIndicator 必须隐藏（集合级不显示单集进度）")
    }
    // playedBadge 隐藏
    if let playedBadge = item.playedBadge {
      XCTAssertTrue(playedBadge.isHidden,
                    "episodeCount != nil 时 playedBadge 必须隐藏")
    }
  }

  /// 谓词：episodeCount=1 → 角标「1集」（边界，单集剧集合）
  func test_configure_episodeCount_one_shows_1集() {
    let item = makeLoadedItem()
    let media = makeRepresentative()

    item.configure(with: media, ignorePath: false, episodeCount: 1)

    guard let badge = item.episodeCountBadge else {
      XCTFail("episodeCount=1 时 episodeCountBadge 必须存在"); return
    }
    XCTAssertEqual(badge.stringValue, "1集", "单集集合角标必须为「1集」")
  }

  /// 谓词：episodeCount=999（大数）→ 角标「999集」（无千分位、无单位变化）
  func test_configure_episodeCount_large_shows_exact() {
    let item = makeLoadedItem()
    let media = makeRepresentative()

    item.configure(with: media, ignorePath: false, episodeCount: 999)

    XCTAssertEqual(item.episodeCountBadge?.stringValue, "999集",
                   "大集数角标必须严格为「999集」")
  }

  /// 谓词：episodeCount=0（边界，contract 语义外但防御）→ 角标「0集」或隐藏
  /// CONTRACT_AMBIGUOUS: 设计文档说 episodeCount ≥ 1（来自 tvShowIndex.count ≥ 1），
  ///   未定义 episodeCount=0 的行为。此测试断言不崩即可（角标存在则显示"0集"）。
  func test_configure_episodeCount_zero_does_not_crash() {
    let item = makeLoadedItem()
    let media = makeRepresentative()

    // 不崩即通过（强断言：执行流到达此处）
    item.configure(with: media, ignorePath: false, episodeCount: 0)
    XCTAssertEqual(item.episodeCountBadge?.stringValue, "0集",
                   "episodeCount=0 若显示角标，文案须为「0集」（contract 未禁止）")
  }

  // MARK: - 契约 5+3 组合：displayName + episodeCount 同时传入（剧集集合卡片实际用法）

  /// 谓词：剧集集合卡片典型用法 —— displayName=纯剧名 + episodeCount=N
  /// 同时覆盖 nameLabel 且显示角标隐藏进度。这是 §3 VC 装配的实际调用形态。
  func test_configure_displayName_and_episodeCount_combined() {
    let item = makeLoadedItem()
    let media = makeRepresentative(cleanedName: "怪奇物语.S05E03", tvShowId: "怪奇物语", epNum: 3)

    item.configure(with: media, ignorePath: false,
                   displayName: "怪奇物语", episodeCount: 8)

    XCTAssertEqual(item.nameLabel?.stringValue, "怪奇物语",
                   "组合调用：nameLabel 必须显示 displayName「怪奇物语」")
    XCTAssertEqual(item.episodeCountBadge?.stringValue, "8集",
                   "组合调用：角标必须「8集」")
    XCTAssertFalse(item.episodeCountBadge?.isHidden ?? true,
                   "组合调用：角标必须可见")
    if let progress = item.progressIndicator {
      XCTAssertTrue(progress.isHidden, "组合调用：progressIndicator 必须隐藏")
    }
  }

  // MARK: - 契约 6：幂等（同一 item 多次 configure 结果一致）

  /// 谓词：对同一 item 连续 configure 两次（参数相同），结果一致
  func test_configure_idempotent_same_call() {
    let item = makeLoadedItem()
    let media = makeRepresentative(cleanedName: "幂等剧", tvShowId: "幂等剧", epNum: 2)

    item.configure(with: media, ignorePath: false, displayName: "幂等剧", episodeCount: 5)
    let nameAfter1 = item.nameLabel?.stringValue
    let badgeAfter1 = item.episodeCountBadge?.stringValue
    let badgeHidden1 = item.episodeCountBadge?.isHidden

    item.configure(with: media, ignorePath: false, displayName: "幂等剧", episodeCount: 5)
    let nameAfter2 = item.nameLabel?.stringValue
    let badgeAfter2 = item.episodeCountBadge?.stringValue
    let badgeHidden2 = item.episodeCountBadge?.isHidden

    XCTAssertEqual(nameAfter1, nameAfter2, "幂等：nameLabel 两次必须一致")
    XCTAssertEqual(badgeAfter1, badgeAfter2, "幂等：角标文案两次必须一致")
    XCTAssertEqual(badgeHidden1, badgeHidden2, "幂等：角标可见性两次必须一致")
  }

  /// 谓词：从 episodeCount 模式切回 nil 模式（同 item 重新 configure）→ 角标隐藏
  /// 应用场景：collectionView 复用 cell，从剧集集合卡片切到普通电影卡片
  func test_configure_reuse_switches_from_group_to_normal() {
    let item = makeLoadedItem()
    let groupMedia = makeRepresentative(cleanedName: "剧X.S01E01", tvShowId: "剧X", epNum: 1)
    let movieMedia = MediaItem(
      url: URL(fileURLWithPath: "/tmp/iina_redteam_card_reuse_movie.mkv"),
      cleanedName: "电影Y", rawName: "电影Y.1080p", category: .movie,
      tvShowId: nil, episodeNumber: nil, duration: 100, thumbnailPath: nil
    )

    // 先 configure 成剧集集合卡片
    item.configure(with: groupMedia, ignorePath: false,
                   displayName: "剧X", episodeCount: 3)
    XCTAssertEqual(item.episodeCountBadge?.stringValue, "3集", "首次 configure 为集合模式")
    XCTAssertFalse(item.episodeCountBadge?.isHidden ?? true)

    // 复用同 cell，configure 成普通电影（episodeCount=nil）
    item.configure(with: movieMedia, ignorePath: false)
    XCTAssertEqual(item.nameLabel?.stringValue, "电影Y",
                   "复用后 nameLabel 必须切到电影 cleanedName")
    // 角标必须隐藏（不复用残留）
    if let badge = item.episodeCountBadge {
      XCTAssertTrue(badge.isHidden || badge.stringValue.isEmpty,
                    "复用 cell 切回普通模式时，角标必须隐藏或清空（防 UI 残留）")
    }
  }
}
