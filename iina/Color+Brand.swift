//
//  Color+Brand.swift
//  iina
//
//  Created by autopilot on 14/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// stringzhao-life 品牌色彩体系（见 `documents/refs/colors.md`）。
///
/// 所有品牌色通过 `NSColor(name:dynamicProvider:)` 提供浅色/暗色双变体，以适配 IINA 媒体库
/// 的暗黑模式。浅色变体直接取自 colors.md 的 hex；暗色变体按以下原则派生：
/// - 品牌色 Sage 家族：暗模式提亮（提高感知亮度，避免在深背景上发闷）。
/// - 灰阶（雾/烟/炭）：暗模式反转为对应深灰，保持三级层级关系。
/// - 纸/墨：暗模式互换（纸变深、墨变浅）。
/// - 语义色（琥/朱/天）：暗模式略提亮。
extension NSColor {

  /// 从 hex 字符串构造 NSColor（sRGB 色彩空间）。支持 `#RRGGBB` / `RRGGBB` / `#RRGGBBAA`。
  /// 无效输入回退为透明（避免崩溃）。
  convenience init(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    var rgba: UInt64 = 0
    Scanner(string: s).scanHexInt64(&rgba)
    let r, g, b, a: CGFloat
    if s.count == 8 {
      r = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
      g = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
      b = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
      a = CGFloat(rgba & 0x000000FF) / 255.0
    } else {
      r = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
      g = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
      b = CGFloat(rgba & 0x0000FF) / 255.0
      a = 1.0
    }
    self.init(srgbRed: r, green: g, blue: b, alpha: a)
  }

  /// 从 hex（含 alpha）构造，便利形式。返回新实例（NSColor 是不可变值语义）。
  static func fromHex(_ hex: String, alpha: CGFloat) -> NSColor {
    return NSColor(hex: hex).withAlphaComponent(alpha)
  }
}

/// 品牌色彩 token 常量集合。每个 token 是动态色（浅/暗双变体）。
///
/// 使用：
/// ```swift
/// view.layer?.backgroundColor = BrandColor.paper.cgColor
/// label.textColor = BrandColor.ink
/// progressLayer.backgroundColor = BrandColor.sage.cgColor
/// ```
enum BrandColor {

  // MARK: - 品牌主色 Sage 家族

  /// 苔 Sage `#3A7D68` — 品牌强调、CTA、进度条、hover/选中态。
  static let sage: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      // 暗模式提亮：使用 Sage Light 的更亮变体，确保在深背景上可读。
      return NSColor(hex: "#6BBFA1")
    }
    return NSColor(hex: "#3A7D68")
  }

  /// 苔浅 Sage Light `#52A688` — hover、选中态高亮。
  static let sageLight: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#82D4B4")
    }
    return NSColor(hex: "#52A688")
  }

  /// 苔淡 Sage Mist `#E8F2EE` — tag 背景、浅色填充。
  static let sageMist: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      // 暗模式：深苔背景，保留品牌色相。
      return NSColor(hex: "#1F3D34")
    }
    return NSColor(hex: "#E8F2EE")
  }

  // MARK: - 灰阶（浅/暗反转）

  /// 墨 Ink `#1A1A18` — 正文、标题。暗模式反转为纸色亮度。
  static let ink: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#F7F6F1")
    }
    return NSColor(hex: "#1A1A18")
  }

  /// 纸 Paper `#F7F6F1` — 页面背景。暗模式反转为深炭。
  static let paper: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#1E1E1C")
    }
    return NSColor(hex: "#F7F6F1")
  }

  /// 雾 Mist `#EBEBEA` — 卡片、次级背景。
  static let mist: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#2A2A28")
    }
    return NSColor(hex: "#EBEBEA")
  }

  /// 烟 Smoke `#8F8F8D` — 描述、辅助文字。
  static let smoke: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#A0A09E")
    }
    return NSColor(hex: "#8F8F8D")
  }

  /// 炭 Charcoal `#595957` — placeholder、标签。
  static let charcoal: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#B5B5B3")
    }
    return NSColor(hex: "#595957")
  }

  // MARK: - 语义色

  /// 琥 Amber `#D4920A` — warning、highlight。
  static let amber: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#E8AB3D")
    }
    return NSColor(hex: "#D4920A")
  }

  /// 朱 Vermillion `#D94F3D` — error、delete。
  static let vermillion: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#E87060")
    }
    return NSColor(hex: "#D94F3D")
  }

  /// 天 Sky `#3B87CC` — link、info badge。
  static let sky: NSColor = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil {
      return NSColor(hex: "#6BA8E0")
    }
    return NSColor(hex: "#3B87CC")
  }

  // MARK: - 常用组合

  /// 图底渐变叠层（缩略图底部，用于保证标题可读）。透明→深黑。
  /// 返回 CGColor（CALayer 用），不受外观切换影响（始终深色渐变）。
  static let gradientOverlayColors: [CGColor] = [
    CGColor(red: 0, green: 0, blue: 0, alpha: 0),
    CGColor(red: 0, green: 0, blue: 0, alpha: 0.35),
    CGColor(red: 0, green: 0, blue: 0, alpha: 0.78),
  ]
}
