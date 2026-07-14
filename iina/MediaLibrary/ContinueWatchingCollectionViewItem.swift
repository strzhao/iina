//
//  ContinueWatchingCollectionViewItem.swift
//  iina
//
//  Created by autopilot on 14/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// Independent horizontal (16:9) collection-view card for the "continue watching" strip.
///
/// Root cause B fix: previously `ContinueWatchingView` registered `MediaItemCollectionViewItem`
/// (the main-grid 200×300 portrait card) into a 160×90 item slot, so the fixed-230-tall thumbnail
/// overflowed and only a sliver showed. This dedicated cell is built for 160×90 from scratch:
/// thumbnail fills 16:9 edge-to-edge, a bottom gradient overlay carries title + remaining time,
/// and a Sage progress bar runs along the very bottom (DC7).
///
/// Built entirely in code (no xib).
class ContinueWatchingCollectionViewItem: NSCollectionViewItem {

  static let identifier = NSUserInterfaceItemIdentifier(rawValue: "ContinueWatchingCollectionViewItem")

  /// Item size (16:9). Matches `ContinueWatchingView.flowLayout.itemSize`.
  static let itemSize = NSSize(width: 160, height: 90)

  // MARK: Subviews

  /// Thumbnail filling the whole item (16:9).
  let thumbnailView = NSImageView()
  /// Title overlaid on the bottom gradient.
  let titleLabel = NSTextField(labelWithString: "")
  /// Remaining-time badge (bottom-right), e.g. "剩 23:14".
  let remainingLabel = NSTextField(labelWithString: "")
  /// Sage progress bar (CALayer-drawn; NSProgressIndicator can't be recolored to Sage easily).
  private let progressTrack = CALayer()
  private let progressFill = CALayer()
  /// Bottom gradient overlay for legibility.
  private let gradientLayer = CAGradientLayer()

  /// The media item represented by this card.
  private(set) var mediaItem: MediaItem?
  /// Thumbnail request token (stale-callback guard, same pattern as main card).
  private var thumbnailToken: UInt64 = 0

  // MARK: Lifecycle

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0,
                                         width: ContinueWatchingCollectionViewItem.itemSize.width,
                                         height: ContinueWatchingCollectionViewItem.itemSize.height))
    container.wantsLayer = true
    // Rounded corners + subtle shadow on the whole card.
    container.layer?.cornerRadius = 6
    container.layer?.masksToBounds = true
    container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    // Thumbnail — fills the entire 160×90 item, 16:9 by construction.
    thumbnailView.translatesAutoresizingMaskIntoConstraints = false
    thumbnailView.imageScaling = .scaleProportionallyUpOrDown
    thumbnailView.imageAlignment = .alignCenter
    thumbnailView.wantsLayer = true
    container.addSubview(thumbnailView)

    // Gradient overlay (transparent → dark) at the bottom ~45% for title legibility.
    gradientLayer.colors = BrandColor.gradientOverlayColors
    gradientLayer.locations = [0, 0.55, 1]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
    gradientLayer.cornerRadius = container.layer?.cornerRadius ?? 6
    container.wantsLayer = true
    container.layer?.addSublayer(gradientLayer)

    // Title (bottom-left).
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.isEditable = false
    titleLabel.isSelectable = false
    titleLabel.maximumNumberOfLines = 1
    titleLabel.cell?.truncatesLastVisibleLine = true
    titleLabel.cell?.wraps = false
    titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    titleLabel.textColor = NSColor.white
    titleLabel.alignment = .left
    titleLabel.backgroundColor = .clear
    container.addSubview(titleLabel)

    // Remaining time (bottom-right).
    remainingLabel.translatesAutoresizingMaskIntoConstraints = false
    remainingLabel.isEditable = false
    remainingLabel.isSelectable = false
    remainingLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    remainingLabel.textColor = NSColor.white.withAlphaComponent(0.9)
    remainingLabel.alignment = .right
    remainingLabel.backgroundColor = .clear
    container.addSubview(remainingLabel)

    // Sage progress bar (CALayer) along the very bottom edge.
    progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
    progressTrack.cornerRadius = 1
    container.layer?.addSublayer(progressTrack)
    progressFill.backgroundColor = BrandColor.sage.cgColor
    progressFill.cornerRadius = 1
    progressTrack.addSublayer(progressFill)

    NSLayoutConstraint.activate([
      thumbnailView.topAnchor.constraint(equalTo: container.topAnchor),
      thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: remainingLabel.leadingAnchor, constant: -6),
      titleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

      remainingLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      remainingLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
      remainingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 70),
    ])

    view = container
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    // Lay out the CALayer overlay/bar using the container's bounds (layers don't use Auto Layout).
    let bounds = view.bounds
    // Gradient: cover whole card; the locations already fade the top portion to transparent.
    gradientLayer.frame = bounds
    // Progress track: full width, 3pt tall, pinned to the bottom.
    let trackHeight: CGFloat = 3
    let trackY: CGFloat = 0
    progressTrack.frame = CGRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)
    let ratio = currentProgressRatio
    progressFill.frame = CGRect(x: 0, y: 0,
                                width: bounds.width * CGFloat(ratio),
                                height: trackHeight)
  }

  /// Cached progress ratio so viewDidLayout can re-draw the fill on resize.
  private var currentProgressRatio: Double = 0

  // MARK: Configuration

  /// Configure the card with a media item and trigger on-demand thumbnail generation.
  func configure(with item: MediaItem, ignorePath: Bool) {
    mediaItem = item
    titleLabel.stringValue = item.cleanedName
    thumbnailView.image = nil
    thumbnailToken &+= 1
    currentProgressRatio = 0

    // Progress (live from watch-later) + remaining-time label.
    if let progressSec = MediaLibraryStore.shared.progress(for: item),
       let duration = item.duration ?? HistoryController.shared.history
         .first(where: { $0.mpvMd5 == Utility.mpvWatchLaterMd5(item.url, ignorePath) })?
         .duration.second,
       duration > 0 {
      let ratio = min(max(progressSec / duration, 0), 1)
      currentProgressRatio = ratio
      let remaining = max(duration - progressSec, 0)
      remainingLabel.stringValue = "剩 \(ContinueWatchingCollectionViewItem.formatTime(remaining))"
    } else {
      remainingLabel.stringValue = ""
    }
    // Force a layout pass to render the progress fill with the new ratio.
    view.needsLayout = true

    // Thumbnail: cached path first, else generate.
    if let thumbPath = item.thumbnailPath, let img = NSImage(contentsOf: thumbPath) {
      thumbnailView.image = img
    } else {
      requestThumbnail(ignorePath: ignorePath)
    }
  }

  private func requestThumbnail(ignorePath: Bool) {
    guard let item = mediaItem else { return }
    let token = thumbnailToken
    MediaThumbnailer.shared.generateThumbnail(for: item.url, ignorePath: ignorePath) { [weak self] image in
      guard let self = self, self.thumbnailToken == token else { return }
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

  /// Format seconds as `H:MM:SS` or `M:SS`.
  private static func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
  }
}
