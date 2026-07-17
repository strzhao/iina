//
//  MediaItemCollectionViewItem.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// A grid card representing one `MediaItem` — immersive cinematic design (DC2/DC3/DC5).
///
/// Built entirely in code (no xib). The card is a pure 16:9 thumbnail (root cause A fix — the old
/// 192×230 portrait frame produced top/bottom black bars on 16:9 screenshots). Core info (title +
/// year + resolution) is overlaid on a bottom gradient (A1, always visible); a hover overlay adds
/// a play affordance + full metadata (codec / bitrate / duration / episodes). Visual depth comes
/// from a CALayer shadow, rounded corners, a hover lift (tracking-area driven), and a Sage selected
/// border (DC5, replaces system blue). The progress bar is CALayer-drawn in Sage.
class MediaItemCollectionViewItem: NSCollectionViewItem {

  static let identifier = NSUserInterfaceItemIdentifier(rawValue: "MediaItemCollectionViewItem")

  /// Fixed card size — pure 16:9 thumbnail, info overlaid on the image (no separate info strip).
  static let cardSize = NSSize(width: 240, height: 135)

  /// Thumbnail width → 16:9 height.
  static let thumbnailAspectRatio: CGFloat = 9.0 / 16.0

  // MARK: Subviews (built in code)

  /// The thumbnail image, filling the whole 16:9 card.
  let thumbnailView = NSImageView()
  /// 缩略图加载占位 spinner（P2-3）。盖在 thumbnailView 上居中，缩略图生成期间可见、回调到达
  /// （成功/失败/超时）后隐藏。`wantsLayer=true` 保证 layer-backed tree 下 indeterminate 动画刷新。
  /// 走系统 `controlAccentColor`（明暗自适应 + 跟用户 Accent，C5），不硬编码浅色 hex。
  let placeholderSpinner = NSProgressIndicator()
  /// Title (always visible, overlaid on bottom gradient).
  let titleLabel = NSTextField(labelWithString: "")
  /// Sub-info line "year · resolution" (always visible, overlaid).
  let subtitleLabel = NSTextField(labelWithString: "")
  /// Episode-count badge for TV-show collection cards (e.g. "12集"). Top-left. Hidden by default.
  let episodeCountBadge = NSTextField(labelWithString: "")
  /// "Played" checkmark badge (top-right). Hidden by default.
  let playedBadge = NSTextField(labelWithString: "已看")

  // MARK: Overlay (hover-only)

  /// Overlay shown on hover: play button + full metadata. Hidden by default.
  private let hoverOverlay = NSView()
  /// Circular frosted-glass play button shown in the overlay center. NSVisualEffectView gives the
  /// real blur; a CAShapeLayer draws a centered triangle on top.
  private let playBadge = NSVisualEffectView()
  private let playTriangleLayer = CAShapeLayer()
  /// Full metadata block (codec · bitrate · duration · episode-count).
  private let metaLabel = NSTextField(labelWithString: "")

  // MARK: Layers

  /// Bottom gradient for title legibility.
  private let gradientLayer = CAGradientLayer()
  /// Sage progress bar track + fill (CALayer-drawn; NSProgressIndicator can't be recolored to Sage).
  private let progressTrackLayer = CALayer()
  private let progressFillLayer = CALayer()

  // MARK: State

  /// The media item represented by this card.
  private(set) var mediaItem: MediaItem?
  /// Thumbnail request token (stale-callback guard).
  private var thumbnailToken: UInt64 = 0
  /// Last computed progress ratio (for CALayer fill on layout).
  private var currentProgressRatio: Double = 0
  /// Tracking area for hover.
  private var trackingArea: NSTrackingArea?

  // MARK: Lifecycle

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0,
                                         width: MediaItemCollectionViewItem.cardSize.width,
                                         height: MediaItemCollectionViewItem.cardSize.height))
    container.wantsLayer = true
    // Shadow + rounded corners on the container's own layer. masksToBounds MUST be false so the
    // shadow renders outside the bounds; the thumbnail's own layer clips its content to the
    // rounded corner via a matching cornerRadius.
    container.layer?.shadowColor = NSColor.black.cgColor
    container.layer?.shadowOpacity = 0.35
    container.layer?.shadowOffset = NSSize(width: 0, height: -2)
    container.layer?.shadowRadius = 8
    container.layer?.cornerRadius = 8
    container.layer?.borderWidth = 0
    container.layer?.borderColor = BrandColor.sageLight.cgColor

    // Thumbnail — 16:9, fills the whole card.
    thumbnailView.translatesAutoresizingMaskIntoConstraints = false
    thumbnailView.imageScaling = .scaleProportionallyUpOrDown
    thumbnailView.imageAlignment = .alignCenter
    thumbnailView.wantsLayer = true
    thumbnailView.layer?.backgroundColor = BrandColor.charcoal.cgColor
    thumbnailView.layer?.cornerRadius = container.layer?.cornerRadius ?? 8
    thumbnailView.layer?.masksToBounds = true
    container.addSubview(thumbnailView)

    // 缩略图加载占位 spinner（P2-3）：盖在 thumbnailView 上居中。wantsLayer=true 保证
    // layer-backed tree 下 indeterminate 动画刷新。controlIndicatorSize=.small 走系统强调色（C5）。
    placeholderSpinner.style = .spinning
    placeholderSpinner.controlSize = .small
    placeholderSpinner.isDisplayedWhenStopped = false
    placeholderSpinner.isIndeterminate = true
    placeholderSpinner.wantsLayer = true
    placeholderSpinner.translatesAutoresizingMaskIntoConstraints = false
    placeholderSpinner.isHidden = true
    placeholderSpinner.setAccessibilityIdentifier("placeholderSpinner")
    container.addSubview(placeholderSpinner)

    // Bottom gradient overlay (transparent → dark) for title legibility.
    gradientLayer.colors = BrandColor.gradientOverlayColors
    gradientLayer.locations = [0, 0.5, 1]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
    container.layer?.addSublayer(gradientLayer)

    // Title (bottom-left, bold white).
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.isEditable = false
    titleLabel.isSelectable = false
    titleLabel.maximumNumberOfLines = 1
    titleLabel.cell?.truncatesLastVisibleLine = true
    titleLabel.cell?.wraps = false
    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = NSColor.white
    titleLabel.alignment = .left
    titleLabel.backgroundColor = .clear
    container.addSubview(titleLabel)

    // Sub-info (below title, smaller, translucent white).
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.isEditable = false
    subtitleLabel.isSelectable = false
    subtitleLabel.maximumNumberOfLines = 1
    subtitleLabel.cell?.truncatesLastVisibleLine = true
    subtitleLabel.cell?.wraps = false
    subtitleLabel.font = NSFont.systemFont(ofSize: 10)
    subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
    subtitleLabel.alignment = .left
    subtitleLabel.backgroundColor = .clear
    container.addSubview(subtitleLabel)

    // Sage progress bar (bottom edge, CALayer-drawn).
    progressTrackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
    progressTrackLayer.cornerRadius = 1.5
    container.layer?.addSublayer(progressTrackLayer)
    progressFillLayer.backgroundColor = BrandColor.sage.cgColor
    progressFillLayer.cornerRadius = 1.5
    progressTrackLayer.addSublayer(progressFillLayer)

    // Episode-count badge (top-left).
    episodeCountBadge.translatesAutoresizingMaskIntoConstraints = false
    episodeCountBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    episodeCountBadge.textColor = NSColor.white
    episodeCountBadge.alignment = .center
    episodeCountBadge.wantsLayer = true
    episodeCountBadge.layer?.cornerRadius = 4
    episodeCountBadge.layer?.backgroundColor = BrandColor.sage.cgColor
    episodeCountBadge.layer?.borderWidth = 0
    episodeCountBadge.isHidden = true
    container.addSubview(episodeCountBadge)

    // Played badge (top-right).
    playedBadge.translatesAutoresizingMaskIntoConstraints = false
    playedBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    playedBadge.textColor = NSColor.white
    playedBadge.alignment = .center
    playedBadge.wantsLayer = true
    playedBadge.layer?.cornerRadius = 4
    playedBadge.layer?.backgroundColor = BrandColor.sage.cgColor
    playedBadge.isHidden = true
    container.addSubview(playedBadge)

    // Hover overlay (play button + full metadata). Hidden by default.
    hoverOverlay.translatesAutoresizingMaskIntoConstraints = false
    hoverOverlay.wantsLayer = true
    hoverOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
    hoverOverlay.layer?.cornerRadius = container.layer?.cornerRadius ?? 8
    hoverOverlay.layer?.masksToBounds = true
    hoverOverlay.isHidden = true
    container.addSubview(hoverOverlay)

    playBadge.translatesAutoresizingMaskIntoConstraints = false
    playBadge.material = .hudWindow
    playBadge.blendingMode = .withinWindow
    playBadge.state = .active
    playBadge.wantsLayer = true
    playBadge.layer?.cornerRadius = 26
    playBadge.layer?.masksToBounds = true
    hoverOverlay.addSubview(playBadge)

    // Centered play triangle (drawn as a path — not a glyph — so there's no font baseline offset).
    // Fixed 52×52 frame so it renders even before the hover overlay is first shown (playBadge is a
    // fixed 52×52 via constraints, but its bounds can still be 0 while the overlay is hidden).
    let trianglePath = CGMutablePath()
    trianglePath.move(to: CGPoint(x: 19, y: 13))
    trianglePath.addLine(to: CGPoint(x: 19, y: 39))
    trianglePath.addLine(to: CGPoint(x: 41, y: 26))
    trianglePath.closeSubpath()
    playTriangleLayer.path = trianglePath
    playTriangleLayer.fillColor = NSColor.white.cgColor
    playTriangleLayer.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
    playBadge.layer?.addSublayer(playTriangleLayer)

    metaLabel.translatesAutoresizingMaskIntoConstraints = false
    metaLabel.isEditable = false
    metaLabel.isSelectable = false
    metaLabel.maximumNumberOfLines = 0
    metaLabel.cell?.wraps = true
    metaLabel.font = NSFont.systemFont(ofSize: 10)
    metaLabel.textColor = NSColor.white
    metaLabel.alignment = .center
    metaLabel.backgroundColor = .clear
    hoverOverlay.addSubview(metaLabel)

    NSLayoutConstraint.activate([
      thumbnailView.topAnchor.constraint(equalTo: container.topAnchor),
      thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      placeholderSpinner.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
      placeholderSpinner.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),

      titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -1),

      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

      episodeCountBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
      episodeCountBadge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
      episodeCountBadge.heightAnchor.constraint(equalToConstant: 18),

      playedBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
      playedBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
      playedBadge.widthAnchor.constraint(equalToConstant: 36),
      playedBadge.heightAnchor.constraint(equalToConstant: 18),

      hoverOverlay.topAnchor.constraint(equalTo: container.topAnchor),
      hoverOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hoverOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hoverOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      playBadge.centerXAnchor.constraint(equalTo: hoverOverlay.centerXAnchor),
      playBadge.centerYAnchor.constraint(equalTo: hoverOverlay.centerYAnchor),
      playBadge.widthAnchor.constraint(equalToConstant: 52),
      playBadge.heightAnchor.constraint(equalToConstant: 52),

      metaLabel.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: 8),
      metaLabel.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -8),
      metaLabel.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -8),
    ])

    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // A recycled cell must never inherit the previous item's hover state.
    isHovering = false
    // P3-9 / C3：复用串味根因之一。重置缩略图相关状态——spinner 停止隐藏、thumbnailView.image
    // 清空、mediaItem 置 nil。mediaItem=nil 防 isReconfigure guard 在 cell 复用同实例 item 时
    // 误判跳过 thumbnail 重置（ISSUE-R2-1）。thumbnailToken 守卫不变（:66/:354）。
    placeholderSpinner.isHidden = true
    placeholderSpinner.stopAnimation(nil)
    thumbnailView.image = nil
    mediaItem = nil
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    // Lay out CALayers using the container bounds (layers don't use Auto Layout).
    let bounds = view.bounds
    // Gradient: cover bottom 60% so the top stays clear; the CAGradientLayer is positioned
    // absolutely because startPoint/endPoint already encode the fade.
    gradientLayer.frame = bounds
    // Progress track: full width, 3pt tall, pinned to the bottom edge.
    let trackHeight: CGFloat = 3
    progressTrackLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: trackHeight)
    progressFillLayer.frame = CGRect(x: 0, y: 0,
                                     width: bounds.width * CGFloat(currentProgressRatio),
                                     height: trackHeight)
    // Pin the shadow to a path so AppKit doesn't re-rasterize the blur every frame (the main
    // cause of scroll jank without shadowPath).
    view.layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
    // Refresh the tracking area so it matches the current bounds.
    installTrackingArea()
    // Hover consistency: when the card scrolls out from under the cursor, mouseExited can be
    // missed (the cell moved, not the cursor). Re-check the live mouse position and clear hover.
    if isHovering {
      let mouseInWindow = view.window?.convertPoint(fromScreen: NSEvent.mouseLocation)
      if let mp = mouseInWindow, !view.bounds.contains(view.convert(mp, from: nil)) {
        isHovering = false
      }
    }
  }

  // MARK: Tracking area (hover)

  /// (Re)install the hover tracking area to match the current view bounds. Called from
  /// `viewDidLayout`. NSCollectionViewItem is an NSResponder, so it can own the tracking area and
  /// receive mouseEntered/Exited.
  private func installTrackingArea() {
    if let existing = trackingArea {
      view.removeTrackingArea(existing)
      trackingArea = nil
    }
    guard view.bounds.width > 0 else { return }
    // `.inVisibleRect` makes AppKit use the view's visibleRect, so the rect param must be .zero
    // (passing view.bounds conflicted with the flag and produced unreliable exit events).
    let area = NSTrackingArea(rect: .zero,
                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                              owner: self, userInfo: nil)
    view.addTrackingArea(area)
    trackingArea = area
  }

  private var isHovering = false {
    didSet {
      guard oldValue != isHovering else { return }
      // Hover lift: translate the container's layer a few points up + deepen the shadow.
      let lift: CGFloat = isHovering ? -4 : 0
      let shadowOp: Float = isHovering ? 0.5 : 0.35
      let duration: TimeInterval = 0.18
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        ctx.allowsImplicitAnimation = true
        view.animator().layer?.transform = CATransform3DMakeTranslation(0, lift, 0)
        view.layer?.shadowOpacity = shadowOp
      })
      // Overlay fade.
      hoverOverlay.isHidden = !isHovering
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        hoverOverlay.animator().alphaValue = isHovering ? 1 : 0
      })
    }
  }

  override func mouseEntered(with event: NSEvent) { isHovering = true }
  override func mouseExited(with event: NSEvent) { isHovering = false }

  // MARK: Selected state (Sage border)

  override var isSelected: Bool {
    didSet {
      guard oldValue != isSelected else { return }
      view.layer?.borderWidth = isSelected ? 2 : 0
      view.layer?.borderColor = BrandColor.sageLight.cgColor
    }
  }

  // MARK: Configuration

  /// Configure the card with a media item. Triggers on-demand thumbnail generation.
  ///
  /// - Parameters:
  ///   - displayName: When non-nil, overrides the title with this string (used by TV-show
  ///     collection cards so the title is the bare show name). When nil, shows `item.cleanedName`.
  ///   - episodeCount: When non-nil, this card represents a TV-show collection: shows the "\(n)集"
  ///     badge and hides the per-episode progress/played badges. When nil, per-episode behavior.
  func configure(with item: MediaItem, ignorePath: Bool,
                 displayName: String? = nil, episodeCount: Int? = nil) {
    // isReconfigure guard（解 plan-reviewer BLOCKER-2，C2）：同一 item 被 reconfigureVisibleItems
    // 重配时（如 metadataProbed 通知链），不清空 thumbnailView.image、不重显 spinner、不
    // thumbnailToken++——只更新 subtitle/meta 文字字段，避免缩略图生成期间打破 spinner 三态。
    // **先判后赋**：在 mediaItem = item 之前读 mediaItem 做比较（ISSUE-R2-1，C3）。
    let isReconfigure = (mediaItem === item)
    mediaItem = item
    titleLabel.stringValue = displayName ?? item.cleanedName
    if !isReconfigure {
      // 新 item 或首次配置：走完整 thumbnail 重置流程。spinner 在 thumbnailView.image=nil 之后、
      // thumbnailToken++ 之前显示（生成中态）。
      thumbnailView.image = nil
      placeholderSpinner.isHidden = false
      placeholderSpinner.startAnimation(nil)
      thumbnailToken &+= 1
      currentProgressRatio = 0
    }

    // Sub-info: "year · resolution".
    subtitleLabel.stringValue = MediaItemCollectionViewItem.buildSubtitle(item: item)
    // Hover overlay metadata block.
    metaLabel.stringValue = MediaItemCollectionViewItem.buildMetaBlock(item: item, episodeCount: episodeCount)

    // TV-show collection mode.
    let isCollection = episodeCount != nil
    episodeCountBadge.isHidden = !isCollection
    if isCollection, let n = episodeCount {
      episodeCountBadge.stringValue = "\(n)集"
      episodeCountBadge.sizeToFit()
      let pad: CGFloat = 10
      let fittedWidth = episodeCountBadge.cell?.cellSize.width ?? 0
      episodeCountBadge.frame.size.width = fittedWidth + pad
    }

    // Progress + played badge (per-episode only).
    playedBadge.isHidden = true
    if !isCollection {
      if let progressSec = MediaLibraryStore.shared.progress(for: item),
         let duration = item.duration ?? HistoryController.shared.history
           .first(where: { $0.mpvMd5 == Utility.mpvWatchLaterMd5(item.url, ignorePath) })?
           .duration.second,
         duration > 0 {
        let ratio = min(max(progressSec / duration, 0), 1)
        currentProgressRatio = ratio
        if ratio >= 0.95 { playedBadge.isHidden = false }
      }
    }
    view.needsLayout = true

    // On-demand thumbnail: cached path first (decode off the main thread to keep scroll smooth),
    // else generate. Stale-callback guard via thumbnailToken. **isReconfigure 时跳过**——同 item
    // 重配不重新触发缩略图加载（已有的 image / spinner 三态不被打破，C2）。
    if !isReconfigure {
      if let thumbPath = item.thumbnailPath {
        let token = thumbnailToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          let img = NSImage(contentsOf: thumbPath)
          DispatchQueue.main.async {
            guard let self = self, self.thumbnailToken == token else { return }
            // 回调到达（成功/失败）：先隐藏 spinner 再设 image。
            self.placeholderSpinner.isHidden = true
            self.placeholderSpinner.stopAnimation(nil)
            self.thumbnailView.image = img ?? NSImage(named: NSImage.folderName)
          }
        }
      } else {
        requestThumbnail(ignorePath: ignorePath)
      }
    }

    // Lazy metadata probe (P3): kick off a background probe for any missing fields (width/height/
    // codec/bitrate/duration/year). Already-cached fields were rendered above; when the probe
    // completes the store posts a notification and the grid re-configures this card with the new
    // data. No-op if already fully probed.
    MediaLibraryStore.shared.probeMetadata(for: item)
  }

  private func requestThumbnail(ignorePath: Bool) {
    guard let item = mediaItem else { return }
    let token = thumbnailToken
    MediaThumbnailer.shared.generateThumbnail(for: item.url, ignorePath: ignorePath) { [weak self] image in
      guard let self = self, self.thumbnailToken == token else { return }
      // 回调到达（成功 image 非空 / 失败 nil）：先隐藏 spinner + stop，再设 image（C2/三态）。
      self.placeholderSpinner.isHidden = true
      self.placeholderSpinner.stopAnimation(nil)
      if let image = image {
        self.thumbnailView.image = image
        let cacheURL = MediaThumbnailer.cacheDirectoryURL()
          .appendingPathComponent(MediaThumbnailer.cacheName(for: item.url, ignorePath: ignorePath) + ".png")
        item.thumbnailPath = cacheURL
      } else {
        self.thumbnailView.image = NSImage(named: NSImage.folderName)
      }
    }
  }

  // MARK: Subtitle / meta formatting

  /// Build the always-visible subtitle: "year · resolution" (omit empty parts).
  private static func buildSubtitle(item: MediaItem) -> String {
    var parts: [String] = []
    if let y = item.year { parts.append(String(y)) }
    if let h = item.height {
      parts.append(heightToResolutionLabel(h))
    }
    return parts.joined(separator: " · ")
  }

  /// Map video height to a coarse resolution label (480p/720p/1080p/4K).
  private static func heightToResolutionLabel(_ h: Int) -> String {
    if h >= 2000 { return "4K" }
    if h >= 1000 { return "1080p" }
    if h >= 700 { return "720p" }
    return "\(h)p"
  }

  /// Build the hover overlay metadata block: codec · bitrate · duration · episodes.
  private static func buildMetaBlock(item: MediaItem, episodeCount: Int?) -> String {
    var lines: [String] = []
    var codecBit: [String] = []
    if let c = item.videoCodec, !c.isEmpty { codecBit.append(c.uppercased()) }
    if let br = item.bitrate {
      codecBit.append(Self.formatBitrate(br))
    }
    if !codecBit.isEmpty { lines.append(codecBit.joined(separator: " · ")) }
    if let d = item.duration, d > 0 { lines.append(formatDuration(d)) }
    if let ec = episodeCount { lines.append("\(ec) 集") }
    return lines.joined(separator: "\n")
  }

  private static func formatBitrate(_ bps: Int) -> String {
    let mbps = Double(bps) / 1_000_000
    if mbps >= 1 {
      return String(format: "%.1f Mbps", mbps)
    }
    return String(format: "%d kbps", bps / 1000)
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
  }
}
