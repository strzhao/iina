//
//  MediaItem.acceptance.test.swift
//  iina
//
//  红队验收测试 — 数据模型 NSSecureCoding（黑盒视角，基于 ## 契约规约）
//
//  覆盖契约：
//    MediaItem.duration: Double?  // VideoTime 未遵循 NSSecureCoding，故用 Double 持久化
//    MediaItem 字段全量：url/cleanedName/rawName/category/tvShowId/episodeNumber/duration/thumbnailPath
//    NSSecureCoding 可编解码（持久化到 media_library_index.plist）
//  覆盖场景 13-P1 [det-machine]: 应用重启后进度数据保留（依赖 MediaItem 可序列化）
//

import XCTest
@testable import iina

final class MediaItemAcceptanceTests: XCTestCase {

  // MARK: - NSSecureCoding 声明

  /// 谓词: 契约「NSSecureCoding 持久化」
  func test_mediaItem_supports_secure_coding() {
    XCTAssertTrue(MediaItem.supportsSecureCoding,
                  "MediaItem 必须声明 supportsSecureCoding == true（用于 NSKeyedArchiver 持久化）")
  }

  // MARK: - 全字段往返编解码

  /// 谓词: 契约「duration: Double?」+ 全字段 NSSecureCoding 往返一致
  func test_mediaItem_roundtrip_all_fields() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/Volumes/nas/movie.mkv"),
      cleanedName: "本日公休",
      rawName: "【前缀】本日公休.1080p.mkv",
      category: .movie,
      tvShowId: nil,
      episodeNumber: nil,
      duration: 3600.5,  // Double? 非空
      thumbnailPath: URL(fileURLWithPath: "/tmp/thumb.png")
    )

    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: MediaItem.self, from: data)

    guard let decoded = unarchived else {
      XCTFail("反序列化结果不得为 nil")
      return
    }

    // 逐字段强断言
    XCTAssertEqual(decoded.url, original.url, "url 往返不一致")
    XCTAssertEqual(decoded.cleanedName, original.cleanedName, "cleanedName 往返不一致")
    XCTAssertEqual(decoded.rawName, original.rawName, "rawName 往返不一致")
    XCTAssertEqual(decoded.category, original.category, "category 往返不一致")
    XCTAssertNil(decoded.tvShowId, "tvShowId 应为 nil")
    XCTAssertNil(decoded.episodeNumber, "episodeNumber 应为 nil")
    XCTAssertEqual(decoded.duration, original.duration, "duration(Double?) 往返不一致")
    XCTAssertEqual(decoded.thumbnailPath, original.thumbnailPath, "thumbnailPath 往返不一致")
  }

  // MARK: - duration: Double? 边界（nil 与非 nil）

  /// 谓词: 契约「duration: Double?」— nil 情况可编解码
  func test_mediaItem_duration_nil_roundtrip() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/tmp/no_duration.mkv"),
      cleanedName: "无时长", rawName: "raw", category: .other,
      tvShowId: nil, episodeNumber: nil,
      duration: nil,  // nil 情况
      thumbnailPath: nil
    )

    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: MediaItem.self, from: data)

    XCTAssertNotNil(decoded, "duration=nil 时反序列化不得为 nil")
    XCTAssertNil(decoded?.duration, "duration 往返后必须仍为 nil")
  }

  /// 谓词: 契约「duration: Double?」— 0.0 边界
  func test_mediaItem_duration_zero_roundtrip() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/tmp/zero.mkv"),
      cleanedName: "零时长", rawName: "raw", category: .movie,
      tvShowId: nil, episodeNumber: nil,
      duration: 0.0,
      thumbnailPath: nil
    )

    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: MediaItem.self, from: data)

    XCTAssertEqual(decoded?.duration, 0.0, "duration=0.0 往返后必须 == 0.0")
  }

  // MARK: - 电视剧 MediaItem 字段

  /// 谓词: 契约电视剧字段（tvShowId/episodeNumber 非 nil）
  func test_mediaItem_tv_show_fields_roundtrip() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/Volumes/nas/tv/stranger_s05e01.mkv"),
      cleanedName: "怪奇物语",
      rawName: "怪奇物语.S05E01.1080p",
      category: .tvShow,
      tvShowId: "怪奇物语",
      episodeNumber: 1,
      duration: 3000.0,
      thumbnailPath: nil
    )

    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: MediaItem.self, from: data)

    XCTAssertEqual(decoded?.tvShowId, "怪奇物语", "tvShowId 往返不一致")
    XCTAssertEqual(decoded?.episodeNumber, 1, "episodeNumber 往返不一致")
    XCTAssertEqual(decoded?.category, .tvShow, "category 往返不一致")
  }

  // MARK: - 数组持久化（模拟 plist 存取）

  /// 谓词: 场景13-P1「应用重启后进度数据保留」依赖 MediaItem 数组可 NSKeyedArchiver 持久化
  /// 谓词: 契约「持久化到 media_library_index.plist」
  func test_mediaItem_array_roundtrip() throws {
    let items = [
      MediaItem(url: URL(fileURLWithPath: "/tmp/m1.mkv"), cleanedName: "电影1", rawName: "r1",
                category: .movie, tvShowId: nil, episodeNumber: nil, duration: 100, thumbnailPath: nil),
      MediaItem(url: URL(fileURLWithPath: "/tmp/m2.mkv"), cleanedName: "电影2", rawName: "r2",
                category: .movie, tvShowId: nil, episodeNumber: nil, duration: 200, thumbnailPath: nil),
      MediaItem(url: URL(fileURLWithPath: "/tmp/tv1.mkv"), cleanedName: "怪奇物语", rawName: "r3",
                category: .tvShow, tvShowId: "怪奇物语", episodeNumber: 1, duration: 300, thumbnailPath: nil),
    ]

    // 模拟写入 plist（NSArray + NSKeyedArchiver）
    let data = try NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: true)
    let unarchived = try NSKeyedUnarchiver.unarchivedObject(
      ofClasses: [NSArray.self, MediaItem.self], from: data) as? [MediaItem]

    XCTAssertNotNil(unarchived, "数组反序列化不得为 nil")
    XCTAssertEqual(unarchived?.count, 3, "数组长度往返不一致")
    XCTAssertEqual(unarchived?[2].episodeNumber, 1, "第 3 项 episodeNumber 往返不一致")
    XCTAssertEqual(unarchived?[0].duration, 100, "第 1 项 duration 往返不一致")
  }

  // MARK: - Mutation-Survival 自检

  /// Return-Value 自检：解码对象与原对象不相等（不同实例）但字段相等
  /// 防止蓝队「返回原对象」的伪实现
  func test_mediaItem_decoded_is_new_instance() throws {
    let original = MediaItem(
      url: URL(fileURLWithPath: "/tmp/identity.mkv"), cleanedName: "x", rawName: "r",
      category: .movie, tvShowId: nil, episodeNumber: nil, duration: 1, thumbnailPath: nil
    )
    let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: MediaItem.self, from: data)

    XCTAssertNotNil(decoded)
    // 字段相等（上面 test 已覆盖），此处仅确认是新实例（指针不同）
    XCTAssertTrue(decoded !== original || decoded == nil,
                  "反序列化必须是新实例，不得返回原对象（伪实现检测）")
  }
}
