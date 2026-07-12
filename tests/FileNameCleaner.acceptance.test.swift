//
//  FileNameCleaner.acceptance.test.swift
//  iina
//
//  红队验收测试 — 文件名清洗器（黑盒视角，基于 ## 契约规约）
//
//  覆盖验收场景：
//    场景 2-P1 [det-machine]: ∀ card: card.text 不匹配 `【.*www\..*\.com】`
//    场景 2-P2 [det-machine]: 「本日公休」清洗后含「本日公休」且不含「高清影视之家」
//    场景 3-P2 [det-machine]: 「怪奇物语」清洗后含「怪奇物语」且不含「高清剧集网」
//  覆盖契约 example（Pact 风格，逐字一致）：
//    Given: 【高清影视之家首发 www.BBEDDE.com】本日公休[国语配音+中文字幕].Day.Off.2023.1080p.Hami.WEB-DL.x264.AAC-MOMOWEB
//    Then:  { cleanedName: "本日公休", episodeNumber: nil, tvShowId: nil }
//    Given: 怪奇物语.第五季[全8集].Stranger.Things.S05E01.1080p...
//    Then:  { cleanedName contains "怪奇物语", episodeNumber: 1, tvShowId != nil }
//

import XCTest
// 注：蓝队负责将本文件接入 iina test target；import 语句按工程实际 module 名调整。
// 此处假设主 target 模块名为 iina（与现有 Swift 文件同 module）。
@testable import iina

final class FileNameCleanerAcceptanceTests: XCTestCase {

  // MARK: - 契约 example 1（逐字一致，失败即挂）

  /// 契约 example：下载站前缀 + 分辨率后缀 + 推广尾缀，电影（无集号）
  /// assert: cleanedName == "本日公休" && episodeNumber == nil && tvShowId == nil
  /// 谓词: 场景2-P2, 契约 example #1
  func test_clean_benri_movie_strips_prefix_and_suffix() {
    let raw = "【高清影视之家首发 www.BBEDDE.com】本日公休[国语配音+中文字幕].Day.Off.2023.1080p.Hami.WEB-DL.x264.AAC-MOMOWEB"
    let result = FileNameCleaner.clean(raw)

    // 契约 assert: cleanedName == "本日公休"
    XCTAssertEqual(result.cleanedName, "本日公休",
                   "cleanedName 必须逐字等于「本日公休」，实际: \(result.cleanedName)")
    // 契约 assert: episodeNumber == nil
    XCTAssertNil(result.episodeNumber,
                 "电影无集号，episodeNumber 必须为 nil，实际: \(String(describing: result.episodeNumber))")
    // 契约 assert: tvShowId == nil
    XCTAssertNil(result.tvShowId,
                 "电影 tvShowId 必须为 nil，实际: \(String(describing: result.tvShowId))")
  }

  // MARK: - 契约 example 2（逐字一致，失败即挂）

  /// 契约 example：电视剧含 S05E01 集号
  /// assert: cleanedName contains "怪奇物语" && episodeNumber == 1 && tvShowId != nil
  /// 谓词: 场景3-P2, 契约 example #2
  func test_clean_stranger_things_extracts_episode() {
    let raw = "怪奇物语.第五季.Stranger.Things.S05E01.1080p.Hami.WEB-DL.x264.AAC-MOMOWEB"
    let result = FileNameCleaner.clean(raw)

    // 契约 assert: cleanedName contains "怪奇物语"
    XCTAssertTrue(result.cleanedName.contains("怪奇物语"),
                  "cleanedName 必须包含「怪奇物语」，实际: \(result.cleanedName)")
    // 契约 assert: episodeNumber == 1
    XCTAssertEqual(result.episodeNumber, 1,
                   "S05E01 → episodeNumber 必须 == 1，实际: \(String(describing: result.episodeNumber))")
    // 契约 assert: tvShowId != nil（电视剧分组）
    XCTAssertNotNil(result.tvShowId,
                    "电视剧 tvShowId 必须非 nil，实际: nil")
  }

  /// 契约 example 变体：含「第五季[全8集]」中文章述
  /// 谓词: 场景3-P2
  func test_clean_stranger_things_with_chinese_season_marker() {
    let raw = "怪奇物语.第五季[全8集].Stranger.Things.S05E01.1080p.WEB-DL"
    let result = FileNameCleaner.clean(raw)

    XCTAssertTrue(result.cleanedName.contains("怪奇物语"),
                  "cleanedName 必须包含「怪奇物语」，实际: \(result.cleanedName)")
    XCTAssertEqual(result.episodeNumber, 1,
                   "S05E01 → episodeNumber 必须 == 1")
  }

  // MARK: - 场景 2-P1 全量前缀去除（∀ card 不匹配下载站前缀）

  /// 谓词: 场景2-P1 [det-machine]: ∀ card: card.text 不匹配 `【.*www\..*\.com】`
  /// 实现：对一组带前缀的样本清洗后，断言无任何结果残留前缀模式
  func test_clean_all_samples_strip_download_site_prefix() {
    let prefixPattern = try! NSRegularExpression(pattern: #"【.*www\..*?\.com】"#)
    let samples = [
      "【高清影视之家首发 www.BBEDDE.com】本日公休[国语配音+中文字幕].Day.Off.2023.1080p",
      "【高清剧集网发布 www.BPHDTV.com】怪奇物语.第五季.Stranger.Things.S05E01.1080p",
      "【电影天堂 www.dygod.com】小丑.Joker.2019.1080p.BluRay",
      "【6v电影 www.6vhdy.com】盗梦空间.Inception.2010.2160p",
    ]
    for sample in samples {
      let result = FileNameCleaner.clean(sample)
      let range = NSRange(result.cleanedName.startIndex..., in: result.cleanedName)
      let match = prefixPattern.firstMatch(in: result.cleanedName, options: [], range: range)
      XCTAssertNil(match,
                   "清洗后不得残留下载站前缀 `【.*www\\..*\\.com】`，输入: \(sample)，结果: \(result.cleanedName)")
    }
  }

  // MARK: - 集号识别格式覆盖（SxxEx / 第N集 / Ex）

  /// 谓词: 契约「集号识别：S(\d+)E(\d+) 或 第(\d+)集 或 E(\d+)」
  func test_clean_episode_number_formats() {
    // S05E01
    XCTAssertEqual(FileNameCleaner.clean("剧名.Show.S01E05.1080p").episodeNumber, 5,
                   "S01E05 → episodeNumber == 5")
    // 第N集
    XCTAssertEqual(FileNameCleaner.clean("剧名.第12集.1080p").episodeNumber, 12,
                   "第12集 → episodeNumber == 12")
    // E05
    XCTAssertEqual(FileNameCleaner.clean("剧名.Show.E07.1080p").episodeNumber, 7,
                   "E07 → episodeNumber == 7")
  }

  // MARK: - 分辨率/编码后缀截断

  /// 谓词: 契约「从首个 `.` 后跟 1080p|2160p|720p|WEB-DL|BluRay|x264|x265|H264|H265|AAC|DTS|DDP|... 开始截断」
  func test_clean_truncates_at_resolution_suffix() {
    let raw = "某电影.1080p.Hami.WEB-DL.x264.AAC-MOMOWEB"
    let result = FileNameCleaner.clean(raw)
    XCTAssertFalse(result.cleanedName.contains("1080p"),
                   "不得残留分辨率标记 1080p，实际: \(result.cleanedName)")
    XCTAssertFalse(result.cleanedName.contains("WEB-DL"),
                   "不得残留编码标记 WEB-DL，实际: \(result.cleanedName)")
    XCTAssertFalse(result.cleanedName.contains("x264"),
                   "不得残留编码标记 x264，实际: \(result.cleanedName)")
  }

  // MARK: - 推广尾缀去除

  /// 谓词: 契约「去推广尾缀：地址发布页.*、6v电影.*、最新电影.* 删除」
  func test_clean_strips_promotional_suffix() {
    let samples = [
      "某电影.地址发布页.com",
      "某电影.6v电影.最新地址",
      "某电影.最新电影.推荐",
    ]
    for sample in samples {
      let result = FileNameCleaner.clean(sample)
      XCTAssertFalse(result.cleanedName.contains("地址发布页"),
                     "不得残留推广尾缀「地址发布页」，输入: \(sample)，结果: \(result.cleanedName)")
      XCTAssertFalse(result.cleanedName.contains("6v电影"),
                     "不得残留推广尾缀「6v电影」，输入: \(sample)，结果: \(result.cleanedName)")
      XCTAssertFalse(result.cleanedName.contains("最新电影"),
                     "不得残留推广尾缀「最新电影」，输入: \(sample)，结果: \(result.cleanedName)")
    }
  }

  // MARK: - 中文名保留 + 英文别名共存

  /// 谓词: 契约「保留中文名：优先取清洗后中文片段；含英文别名时保留」
  func test_clean_preserves_chinese_and_english_alias() {
    let raw = "本日公休.Day.Off.2023.1080p"
    let result = FileNameCleaner.clean(raw)
    XCTAssertTrue(result.cleanedName.contains("本日公休"),
                  "必须保留中文名「本日公休」，实际: \(result.cleanedName)")
    // CONTRACT_AMBIGUOUS: 设计文档说「含英文别名时保留」，但未明确分隔符与保留顺序。
    // 此处仅强断言中文名必须存在，英文别名保留为软期望（不强制断言，避免契约歧义误判）。
  }

  // MARK: - Mutation-Survival 自检

  /// No-op 自检：空字符串输入不得崩溃，结果为空字符串
  func test_clean_empty_input_no_crash() {
    let result = FileNameCleaner.clean("")
    XCTAssertEqual(result.cleanedName, "",
                   "空输入 → cleanedName 必须为空字符串，实际: \(result.cleanedName)")
    XCTAssertNil(result.episodeNumber, "空输入 → episodeNumber 必须为 nil")
    XCTAssertNil(result.tvShowId, "空输入 → tvShowId 必须为 nil")
  }

  /// Boundary 自检：纯英文无集号
  func test_clean_pure_english_no_episode() {
    let raw = "Inception.2010.1080p.BluRay"
    let result = FileNameCleaner.clean(raw)
    XCTAssertNil(result.episodeNumber,
                 "纯英文电影无集号，episodeNumber 必须为 nil")
  }

  /// Return-Value 自检：清洗结果与输入不可相等（必须发生变换）
  func test_clean_result_differs_from_input_when_prefix_present() {
    let raw = "【高清影视之家首发 www.BBEDDE.com】本日公休.1080p"
    let result = FileNameCleaner.clean(raw)
    XCTAssertNotEqual(result.cleanedName, raw,
                      "带前缀输入清洗后必须与原输入不同（必须发生变换）")
  }
}
