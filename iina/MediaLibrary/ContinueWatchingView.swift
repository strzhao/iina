//
//  ContinueWatchingView.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// A horizontal strip showing "continue watching" items at the top of the media library window.
///
/// Doubles as its own collection-view data source / delegate / flow layout. Clicking an item opens
/// it for playback via the configured `onOpenItem` closure.
class ContinueWatchingView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

  static let itemIdentifier = NSUserInterfaceItemIdentifier(rawValue: "ContinueWatchingItem")

  private let scrollView = NSScrollView()
  private let collectionView: NSCollectionView
  private let titleLabel = NSTextField(labelWithString: "继续观看")
  private var items: [ContinueWatchingEntry] = []
  private let flowLayout: NSCollectionViewFlowLayout

  /// Called when the user opens a non-TV continue-watching item (direct playback).
  var onOpenItem: ((MediaItem) -> Void)?
  /// B.2：剧集入口点击 → 打开整剧续播（对偶 onOpenItem；与主网格 onSelectTVShow 分流一致）。
  var onSelectTVShow: ((MediaItem) -> Void)?

  override init(frame frameRect: NSRect) {
    flowLayout = NSCollectionViewFlowLayout()
    flowLayout.itemSize = ContinueWatchingCollectionViewItem.itemSize
    flowLayout.minimumInteritemSpacing = 8
    flowLayout.minimumLineSpacing = 8
    flowLayout.scrollDirection = .horizontal
    collectionView = NSCollectionView()
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  private func setup() {
    wantsLayer = true

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textColor = NSColor.labelColor
    addSubview(titleLabel)

    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.backgroundColors = [.clear]
    collectionView.collectionViewLayout = flowLayout
    collectionView.register(ContinueWatchingCollectionViewItem.self, forItemWithIdentifier: ContinueWatchingView.itemIdentifier)
    collectionView.isSelectable = true

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.documentView = collectionView

    addSubview(scrollView)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      titleLabel.heightAnchor.constraint(equalToConstant: 20),

      scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
  }

  /// Update the displayed entries (representative item + precomputed progress).
  func update(with items: [ContinueWatchingEntry]) {
    self.items = items
    titleLabel.stringValue = items.isEmpty ? "" : "继续观看"
    isHidden = items.isEmpty
    collectionView.reloadData()
  }

  // MARK: DataSource

  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    return items.count
  }

  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    guard let item = collectionView.makeItem(withIdentifier: ContinueWatchingView.itemIdentifier, for: indexPath) as? ContinueWatchingCollectionViewItem else {
      return NSCollectionViewItem()
    }
    if let entry = items[at: indexPath.item] {
      item.configure(with: entry, ignorePath: PlayerCore.activeOrNew.ignorePathInWatchLaterConfig)
    }
    return item
  }

  // MARK: Delegate

  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let idx = indexPaths.first?.item, let entry = items[at: idx] else { return }
    // B.2 剧集分流：剧集入口走 onSelectTVShow（整剧续播），其余走 onOpenItem（直接播）。
    let mediaItem = entry.item
    if mediaItem.category == .tvShow, mediaItem.tvShowId != nil {
      onSelectTVShow?(mediaItem)
    } else {
      onOpenItem?(mediaItem)
    }
    collectionView.deselectItems(at: indexPaths)
  }
}
