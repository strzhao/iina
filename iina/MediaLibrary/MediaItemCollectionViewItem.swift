//
//  MediaItemCollectionViewItem.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// A grid card representing one `MediaItem`: thumbnail + cleaned name + progress bar + played badge.
///
/// Built entirely in code (no xib) to avoid extra project file entries. Thumbnails are generated
/// on-demand when the item is configured (i.e. when it becomes visible).
class MediaItemCollectionViewItem: NSCollectionViewItem {

  static let identifier = NSUserInterfaceItemIdentifier(rawValue: "MediaItemCollectionViewItem")

  /// Fixed card size.
  static let cardSize = NSSize(width: 200, height: 300)

  // MARK: Subviews (built in code)

  /// The thumbnail image. Reuses the inherited `imageView` by assigning a custom one.
  let thumbnailView = NSImageView()
  /// Display name (cleaned).
  let nameLabel = NSTextField(labelWithString: "")
  /// Progress bar for playback progress (hidden when no progress).
  let progressIndicator = NSProgressIndicator()
  /// "Played" badge overlay (hidden by default).
  let playedBadge = NSTextField(labelWithString: "已看")
  /// Episode-count badge for TV-show collection cards (e.g. "12集"). Top-left corner. Hidden by
  /// default; shown when `configure(... episodeCount:)` is passed a non-nil value.
  let episodeCountBadge = NSTextField(labelWithString: "")

  /// The media item represented by this card.
  private(set) var mediaItem: MediaItem?
  /// Thumbnail request token. Incremented on each `configure`; stale callbacks (whose token
  /// doesn't match the current one) are dropped to prevent a recycled item from showing the
  /// previous video's thumbnail (fixes B1).
  private var thumbnailToken: UInt64 = 0

  // MARK: Lifecycle

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: MediaItemCollectionViewItem.cardSize.width, height: MediaItemCollectionViewItem.cardSize.height))

    // Thumbnail
    thumbnailView.translatesAutoresizingMaskIntoConstraints = false
    thumbnailView.imageScaling = .scaleProportionallyUpOrDown
    thumbnailView.imageAlignment = .alignCenter
    thumbnailView.wantsLayer = true
    thumbnailView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    thumbnailView.layer?.cornerRadius = 6
    container.addSubview(thumbnailView)

    // Name
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.isEditable = false
    nameLabel.isSelectable = false
    nameLabel.maximumNumberOfLines = 2
    nameLabel.cell?.truncatesLastVisibleLine = true
    nameLabel.cell?.wraps = true
    nameLabel.font = NSFont.systemFont(ofSize: 12)
    nameLabel.textColor = NSColor.labelColor
    nameLabel.alignment = .center
    container.addSubview(nameLabel)

    // Progress
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false
    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 1
    progressIndicator.controlSize = .small
    progressIndicator.isHidden = true
    container.addSubview(progressIndicator)

    // Played badge
    playedBadge.translatesAutoresizingMaskIntoConstraints = false
    playedBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    playedBadge.textColor = NSColor.white
    playedBadge.alignment = .center
    playedBadge.wantsLayer = true
    playedBadge.layer?.cornerRadius = 4
    playedBadge.layer?.backgroundColor = NSColor.systemGreen.cgColor
    playedBadge.isHidden = true
    container.addSubview(playedBadge)

    // Episode-count badge (top-left), shown for TV-show collection cards.
    episodeCountBadge.translatesAutoresizingMaskIntoConstraints = false
    episodeCountBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    episodeCountBadge.textColor = NSColor.white
    episodeCountBadge.alignment = .center
    episodeCountBadge.wantsLayer = true
    episodeCountBadge.layer?.cornerRadius = 4
    episodeCountBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
    episodeCountBadge.isHidden = true
    container.addSubview(episodeCountBadge)

    NSLayoutConstraint.activate([
      thumbnailView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
      thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
      thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
      thumbnailView.heightAnchor.constraint(equalToConstant: 230),

      nameLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
      nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
      nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
      nameLabel.heightAnchor.constraint(equalToConstant: 34),

      progressIndicator.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
      progressIndicator.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
      progressIndicator.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -6),
      progressIndicator.heightAnchor.constraint(equalToConstant: 8),

      playedBadge.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 6),
      playedBadge.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -6),
      playedBadge.widthAnchor.constraint(equalToConstant: 36),
      playedBadge.heightAnchor.constraint(equalToConstant: 18),

      episodeCountBadge.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 6),
      episodeCountBadge.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: 6),
      episodeCountBadge.heightAnchor.constraint(equalToConstant: 18),
    ])

    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Wire the inherited imageView to our thumbnailView so NSCollectionViewItem machinery works.
    // (We can't assign the readonly `imageView` directly; instead our code uses thumbnailView.)
  }

  // MARK: Configuration

  /// Configure the card with a media item. Triggers on-demand thumbnail generation.
  ///
  /// - Parameters:
  ///   - displayName: When non-nil, overrides `nameLabel` with this string (used by TV-show
  ///     collection cards so the title is the bare show name rather than a representative
  ///     episode's `cleanedName`). When nil, `nameLabel` shows `item.cleanedName` (legacy).
  ///   - episodeCount: When non-nil, this card represents a TV-show collection: shows the
  ///     "\(n)集" badge and hides the per-episode `progressIndicator` / `playedBadge`. When nil,
  ///     legacy per-episode behavior applies.
  func configure(with item: MediaItem, ignorePath: Bool,
                 displayName: String? = nil, episodeCount: Int? = nil) {
    mediaItem = item
    nameLabel.stringValue = displayName ?? item.cleanedName
    thumbnailView.image = nil
    thumbnailToken &+= 1  // invalidate any in-flight stale callback

    // TV-show collection mode: show episode-count badge, hide per-episode overlays.
    let isCollection = episodeCount != nil
    episodeCountBadge.isHidden = !isCollection
    if isCollection, let n = episodeCount {
      episodeCountBadge.stringValue = "\(n)集"
      episodeCountBadge.sizeToFit()
      // Keep a readable hit area after sizeToFit (height fixed by constraint; widen + pad).
      let pad: CGFloat = 10
      let fittedWidth = episodeCountBadge.cell?.cellSize.width ?? 0
      episodeCountBadge.frame.size.width = fittedWidth + pad
    }

    if isCollection {
      progressIndicator.isHidden = true
      playedBadge.isHidden = true
    } else {
      progressIndicator.isHidden = true
      playedBadge.isHidden = true
      // Progress from history.
      if let progressSec = MediaLibraryStore.shared.progress(for: item),
         let duration = item.duration ?? HistoryController.shared.history
           .first(where: { $0.mpvMd5 == Utility.mpvWatchLaterMd5(item.url, ignorePath) })?
           .duration.second,
         duration > 0 {
        let ratio = min(max(progressSec / duration, 0), 1)
        progressIndicator.doubleValue = ratio
        progressIndicator.isHidden = false
        if ratio >= 0.95 {
          playedBadge.isHidden = false
        }
      }
    }

    // On-demand thumbnail: try cached path first, else generate.
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
      // Drop stale callbacks from a previous configure (item may have been recycled to a
      // different MediaItem while this request was in flight).
      guard let self = self, self.thumbnailToken == token else { return }
      if let image = image {
        self.thumbnailView.image = image
        // Persist the path on the item for fast reload.
        let cacheURL = MediaThumbnailer.cacheDirectoryURL()
          .appendingPathComponent(MediaThumbnailer.cacheName(for: item.url, ignorePath: ignorePath) + ".png")
        item.thumbnailPath = cacheURL
      } else {
        // Placeholder: a system image indicating no thumbnail.
        self.thumbnailView.image = NSImage(named: NSImage.folderName)
      }
    }
  }
}
