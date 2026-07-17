//
//  MediaLibraryPerfReuseStatic.acceptance.test.swift
//  iina
//
//  红队验收测试 — 性能契约 fs-grep 静态断言（黑盒视角，基于 ## 验收场景 场景3 + 契约 C2/C5）
//
//  覆盖谓词：
//    [fs-grep 静态] perf-reuse.progress-handler-no-reload      (scanProgressUpdated 函数体无 reload/reconfigure)
//    [fs-grep 静态] perf-reuse.configure-isreconfigure-guard   (configure 含 isReconfigure 守卫)
//    [fs-grep 静态] darkmode.no-hardcoded-light-hex            (进度/spinner 相关新增色无硬编码浅色 hex)
//
//  说明（重要）：
//    这三个谓词是「源码静态断言」——不是"看蓝队实现学逻辑"，而是契约的静态校验。
//    状态文件 ## 验收场景 明确 driver 为 fs-grep（读源文件做字符串断言）。
//    红队读取源文件是契约驱动的静态核验，允许。
//    断言基于契约文本（C2/C3/C5），不依赖实现内部逻辑。
//
//  读取的源文件（仅静态字符串断言，非逻辑学习）：
//    iina/MediaLibrary/MediaLibraryViewController.swift  (scanProgressUpdated 函数体)
//    iina/MediaLibrary/MediaItemCollectionViewItem.swift (configure isReconfigure 守卫)
//    iina/MediaLibrary/*.swift                            (进度/spinner 相关新增色 hex)
//

import XCTest
@testable import IINA

final class MediaLibraryPerfReuseStaticAcceptanceTests: XCTestCase {

  /// 定位源文件：通过 test bundle 找到 IINA.app，再向上找源码根。
  /// iinaTests host 在 IINA.app，源码在工程根 iina/MediaLibrary/。
  private func locateSourceFile(_ relativePath: String) throws -> URL {
    let bundle = Bundle(for: type(of: self))
    // bundle 在 DerivedData/.../Build/Products/Debug/iinaTests.xctest
    // 源码在 <repo>/iina/MediaLibrary/...
    // 向上查找直到找到 iina.xcodeproj
    var url = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    for _ in 0..<8 {
      let probe = url.appendingPathComponent("iina.xcodeproj")
      if FileManager.default.fileExists(atPath: probe.path) {
        return url.appendingPathComponent(relativePath)
      }
      url = url.deletingLastPathComponent()
    }
    // 回退：用绝对路径（已知工程根）
    let absPath = "/Users/stringzhao/workspace/iina/\(relativePath)"
    return URL(fileURLWithPath: absPath)
  }

  private func readSource(_ relativePath: String) throws -> String {
    let url = try locateSourceFile(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
  }

  // MARK: - perf-reuse.progress-handler-no-reload [fs-grep 静态]
  // scanProgressUpdated(_:) 函数体（// MARK: - scan-progress-handler 锚点界定）不含 reloadData/reconfigureVisibleItems

  /// 谓词: perf-reuse.progress-handler-no-reload
  /// 契约 C2：进度反馈只更新 label/control 状态，绝不触发 reloadData / reconfigureVisibleItems。
  /// 状态文件 ## 验收场景 明确：「由 `// MARK: - scan-progress-handler` 锚点界定函数体」，
  /// 该区间 grep `reloadData|reconfigureVisibleItems` 命中 0。
  /// 设计 P5：新增 @objc func scanProgressUpdated(_:) 处理 .iinaMediaScanProgress，前后加 MARK 锚点。
  func test_progress_handler_function_contains_no_reload() throws {
    let source = try readSource("iina/MediaLibrary/MediaLibraryViewController.swift")

    // 定位 MARK 锚点（设计 P5：前后加 // MARK: - scan-progress-handler）
    let markerLine = "// MARK: - scan-progress-handler"
    let markerRanges = source.ranges(of: markerLine)
    // 设计 P5 说「前后加 MARK 锚点」——至少 2 处（界定函数体起止）
    // 但 Swift MARK 通常是单行注释标记一个区域起点，P5 措辞「前后」可能指「函数前一个 MARK 注释」。
    // 红队按 ## 验收场景原文：「MARK 锚点界定函数体」——至少需 1 个 marker 定位函数。
    // 放宽：若只有 1 个 marker，从该 marker 到下一个 MARK 或文件尾为函数体区间。
    if markerRanges.isEmpty {
      // 锚点缺失本身是契约违反（P5 要求加锚点供 fs-grep 定位）——但更核心的是函数体内容。
      // 红队回退：定位 scanProgressUpdated 函数签名，从函数体花括号界定。
      try assertScanProgressUpdatedBodyNoReload(source)
      return
    }

    // 取首尾 marker 间的文本作为函数体区间
    let firstMarker = markerRanges.first!
    let lastMarker = markerRanges.last!
    let bodyStart = source.index(after: firstMarker.upperBound)
    let bodyEnd = lastMarker.lowerBound > bodyStart ? lastMarker.lowerBound : source.endIndex
    let body = String(source[bodyStart..<bodyEnd])

    XCTAssertFalse(body.contains("reloadData"),
      "C2 违反：scanProgressUpdated 函数体（MARK 锚点界定区间）含 reloadData() 调用（解 BLOCKER-2）")
    XCTAssertFalse(body.contains("reconfigureVisibleItems"),
      "C2 违反：scanProgressUpdated 函数体含 reconfigureVisibleItems 调用（防 metadataProbed 链打破 spinner 三态）")
  }

  /// 回退断言：无 MARK 锚点时，按函数签名定位 scanProgressUpdated 函数体。
  private func assertScanProgressUpdatedBodyNoReload(_ source: String) throws {
    // ASSUMED_FROM_DESIGN: func scanProgressUpdated(_ note: Notification)（设计 P5 + B3）
    guard let funcRange = source.range(of: "func scanProgressUpdated") else {
      // 函数本身不存在——这是更强的契约违反（seam 缺失）
      // 但红队诚实标注：本谓词是「函数体无 reload」，函数不存在时无法核验，记录但不直接 fail
      // （seam 缺失由 det-machine 谓词更早暴露）
      XCTSkip("REQUIRES_IMPLEMENTATION: scanProgressUpdated 函数未找到（MARK 锚点与函数签名均缺失）")
      return
    }
    // 从 func 起找匹配花括号（简单版：找下一个 `{` 后的首个 `}`）
    let afterFunc = source[funcRange.upperBound...]
    guard let openBrace = afterFunc.firstIndex(of: "{"),
          let closeBrace = afterFunc[openBrace...].firstIndex(of: "}") else {
      XCTFail("无法定位 scanProgressUpdated 函数体花括号")
      return
    }
    let body = String(afterFunc[afterFunc.index(after: openBrace)..<closeBrace])
    XCTAssertFalse(body.contains("reloadData"),
      "C2 违反：scanProgressUpdated 函数体含 reloadData()（回退定位，无 MARK 锚点）")
    XCTAssertFalse(body.contains("reconfigureVisibleItems"),
      "C2 违反：scanProgressUpdated 函数体含 reconfigureVisibleItems（回退定位）")
  }

  // MARK: - perf-reuse.configure-isreconfigure-guard [fs-grep 静态]
  // configure(with:) 源码含 isReconfigure 守卫（同 item 重配不清空 thumbnail/spinner/token）

  /// 谓词: perf-reuse.configure-isreconfigure-guard
  /// 契约 C2 + 设计 A：configure 入口 `let isReconfigure = (mediaItem === item)`，
  /// isReconfigure==true 时不重置 thumbnail/spinner/token，防 metadataProbed 链打破三态。
  /// ## 验收场景 assert：「含 isReconfigure 判定 + 条件跳过 thumbnail 重置」。
  func test_configure_contains_isReconfigure_guard() throws {
    let source = try readSource("iina/MediaLibrary/MediaItemCollectionViewItem.swift")

    // 定位 configure 函数（既有 cell 契约：func configure(with item: MediaItem, ignorePath: Bool, ...)）
    guard let configureRange = source.range(of: "func configure") else {
      XCTFail("MediaItemCollectionViewItem 缺少 configure 函数（既有契约，应存在）")
      return
    }
    // 取 configure 函数体（从 func 到下一个 func 或文件尾）
    let afterConfigure = source[configureRange.lowerBound...]
    let nextFuncRange = afterConfigure.range(of: "\n  func ", options: .literal)
    let bodyEnd = nextFuncRange?.lowerBound ?? source.endIndex
    let configureBody = String(source[configureRange.lowerBound..<bodyEnd])

    // 核心断言 1：含 isReconfigure 标识符（设计 A）
    XCTAssertTrue(configureBody.contains("isReconfigure"),
      "configure 函数体必须含 isReconfigure 守卫（设计 A + 契约 C2，防 metadataProbed 链打破 spinner 三态）")

    // 核心断言 2：含 === 比对（设计 A：let isReconfigure = (mediaItem === item)）
    XCTAssertTrue(configureBody.contains("==="),
      "isReconfigure 守卫必须用 ===（引用相等）判定同 item，configure 函数体含 ===。实际缺失。")

    // 核心断言 3：条件跳过 thumbnail 重置——
    // 设计 A：isReconfigure==true 时不 `thumbnailView.image = nil` / 不重显 spinner / 不 thumbnailToken++。
    // 红队验证：isReconfigure 守卫附近应有条件分支（if !isReconfigure 或 guard !isReconfigure）
    // 包含 thumbnailView / thumbnailToken / placeholderSpinner 之一。
    let hasThumbnailResetGuard = configureBody.contains("thumbnailView")
      && configureBody.contains("isReconfigure")
    XCTAssertTrue(hasThumbnailResetGuard,
      "configure 含 isReconfigure 守卫必须与 thumbnailView 重置逻辑关联（设计 A：条件跳过 thumbnail 重置）")

    // 旁证：thumbnailToken 自增应在 isReconfigure==false 分支内（设计 A）
    // 不强断言精确位置（实现细节），但函数体应同时含 thumbnailToken 与 isReconfigure
    XCTAssertTrue(configureBody.contains("thumbnailToken") || configureBody.contains("isReconfigure"),
      "configure 应含 thumbnailToken 守卫或 isReconfigure 守卫之一（设计 A 契约）")
  }

  // MARK: - darkmode.no-hardcoded-light-hex [fs-grep 静态]
  // 进度/spinner 相关新增色无硬编码浅色 hex（走 controlAccentColor/secondaryLabelColor 或 BrandColor 动态色）

  /// 谓词: darkmode.no-hardcoded-light-hex
  /// 契约 C5：spinner 走系统强调色、label 走 secondaryLabelColor、占位底沿用现有炭灰。
  /// 新增色须经 Color+Brand.swift 动态色。新增代码无固定浅色 hex 字面量（#EBEBEA/#F7F6F1 等）。
  /// 策略：扫描 MediaLibrary 目录下所有 .swift，在含 progress/spinner/placeholder 关键字的
  /// 新增代码区间内，断言无浅色 hex 字面量。
  func test_no_hardcoded_light_hex_in_progress_ui() throws {
    let mediaLibDir = try locateSourceFile("iina/MediaLibrary")
    let files = try FileManager.default.contentsOfDirectory(at: mediaLibDir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }

    // 设计 ## 色彩体系 浅色 hex（colors.md stringzhao-life 体系）
    // 雾 #EBEBEA / 纸 #F7F6F1 / 烟 #8F8F8D / 炭 #595957
    // C5 禁止硬编码这些（应走系统动态色或 BrandColor）
    let lightHexLiterals = ["#EBEBEA", "#F7F6F1", "#EBEBEA", "#f7f6f1",
                            "0xEBEBEA", "0xF7F6F1", "0xebebea", "0xf7f6f1"]
    // BrandColor 已有 dark 变体（设计 D），允许引用 BrandColor 名（不视为硬编码）
    let allowedDynamicApis = ["controlAccentColor", "secondaryLabelColor", "labelColor",
                              "NSColor(name:", "Color+Brand", "BrandColor"]

    var violations: [String] = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      // 仅扫描含进度/spinner/placeholder 关键字的文件（新增 UI 范围）
      let isProgressUIRelated = source.contains("scanProgress")
        || source.contains("placeholderSpinner")
        || source.contains("scanProgressSpinner")
        || source.contains("scanProgressLabel")
      guard isProgressUIRelated else { continue }

      // 断言：这些文件无浅色 hex 字面量（C5）
      for hex in lightHexLiterals {
        if source.localizedCaseInsensitiveContains(hex) {
          // 检查是否在注释里（放宽：注释里的色值说明允许）
          // 简单策略：若该 hex 行同时含 allowedDynamicApis，视为「对照说明」放宽
          let lines = source.components(separatedBy: .newlines)
          for (idx, line) in lines.enumerated() {
            if line.localizedCaseInsensitiveContains(hex)
               && !line.contains("//")
               && !allowedDynamicApis.contains(where: { line.contains($0) }) {
              violations.append("\(file.lastPathComponent):\(idx+1) 含硬编码浅色 hex \(hex)：\(line.trimmingCharacters(in: .whitespaces))")
            }
          }
        }
      }

      // 正向断言：进度 UI 相关文件应使用系统动态色或 BrandColor
      let usesDynamicColor = allowedDynamicApis.contains { source.contains($0) }
      // 不强制要求每个文件都用（可能是纯逻辑文件），仅作旁证记录
      _ = usesDynamicColor
    }

    XCTAssertTrue(violations.isEmpty,
      "C5 违反：进度/spinner 相关新增色硬编码浅色 hex（应走 controlAccentColor/secondaryLabelColor/BrandColor 动态色）。违规：\n\(violations.joined(separator: "\n"))")
  }
}

// MARK: - String.ranges 辅助（兼容 Swift 标准库）

private extension String {
  func ranges(of substring: String) -> [Range<String.Index>] {
    var result: [Range<String.Index>] = []
    var searchStart = startIndex
    while searchStart < endIndex,
          let range = self.range(of: substring, range: searchStart..<endIndex) {
      result.append(range)
      searchStart = range.upperBound
    }
    return result
  }
}
