//
//  MediaLibraryViewController.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// Main view controller for the media library window.
///
/// Layout: top continue-watching strip + category segmented control + search field + a grid
/// `NSCollectionView`. Thumbnails are generated on-demand as cards become visible. Listens to
/// `.iinaHistoryUpdated` and `MediaLibraryStore.scannedNotification` to refresh.
class MediaLibraryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

  static let itemIdentifier = NSUserInterfaceItemIdentifier(rawValue: "MediaLibraryGridItem")

  // MARK: Subviews

  private let continueWatchingView = ContinueWatchingView()
  private let segmentedControl = NSSegmentedControl(labels: ["电影", "电视剧", "其它"], trackingMode: .selectOne, target: nil, action: nil)
  private let searchField = NSSearchField()
  private let scrollView = NSScrollView()
  private let collectionView: NSCollectionView
  private let flowLayout: NSCollectionViewFlowLayout
  private let emptyStateLabel = NSTextField(labelWithString: "")
  private let errorLabel = NSTextField(labelWithString: "")

  // MARK: State

  // Internal (not private) so @testable acceptance tests can verify state invariants
  // (see tests/MediaLibraryViewControllerCategorySwitch.acceptance.test.swift).
  var displayedItems: [MediaItem] = []
  /// When non-empty (TV-show category only), parallels `displayedItems`: each entry is the episode
  /// count for the corresponding representative card. Empty for non-TV categories (per-episode cards).
  var displayedGroupCounts: [Int] = []
  var currentCategory: MediaCategory = .movie
  var currentFilter: String = ""

  /// Height constraint for `continueWatchingView`, toggled in `refresh()` so the strip doesn't
  /// reserve 130pt when empty (Auto Layout keeps a hidden view's frame, so `isHidden` alone
  /// would leave a blank gap at the top).
  var continueWatchingHeightConstraint: NSLayoutConstraint!

  /// Called when a media item is double-clicked (open for playback).
  var onOpenItem: ((MediaItem) -> Void)?
  /// Called when a TV show card is single-clicked (show episode list).
  var onSelectTVShow: ((MediaItem) -> Void)?

  // MARK: Init

  init() {
    flowLayout = NSCollectionViewFlowLayout()
    flowLayout.itemSize = MediaItemCollectionViewItem.cardSize
    flowLayout.minimumInteritemSpacing = 10
    flowLayout.minimumLineSpacing = 12
    flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    collectionView = NSCollectionView()
    collectionView.collectionViewLayout = flowLayout
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  // MARK: View lifecycle

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 680))

    continueWatchingView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(continueWatchingView)

    segmentedControl.translatesAutoresizingMaskIntoConstraints = false
    segmentedControl.target = self
    segmentedControl.action = #selector(categoryChanged(_:))
    segmentedControl.selectedSegment = 0
    container.addSubview(segmentedControl)

    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.placeholderString = "搜索…"
    searchField.target = self
    searchField.action = #selector(searchChanged(_:))
    (searchField.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false
    searchField.sendsSearchStringImmediately = true
    container.addSubview(searchField)

    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.backgroundColors = [.clear]
    collectionView.isSelectable = true
    collectionView.register(MediaItemCollectionViewItem.self, forItemWithIdentifier: MediaLibraryViewController.itemIdentifier)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.documentView = collectionView
    container.addSubview(scrollView)

    emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyStateLabel.font = NSFont.systemFont(ofSize: 14)
    emptyStateLabel.textColor = NSColor.secondaryLabelColor
    emptyStateLabel.alignment = .center
    emptyStateLabel.isHidden = true
    container.addSubview(emptyStateLabel)

    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    errorLabel.font = NSFont.systemFont(ofSize: 13)
    errorLabel.textColor = NSColor.systemRed
    errorLabel.alignment = .center
    errorLabel.isHidden = true
    errorLabel.isSelectable = true
    container.addSubview(errorLabel)

    // Hold the continue-watching height so refresh() can collapse it to 0 when empty.
    continueWatchingHeightConstraint = continueWatchingView.heightAnchor.constraint(equalToConstant: 130)

    NSLayoutConstraint.activate([
      continueWatchingView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      continueWatchingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      continueWatchingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      continueWatchingHeightConstraint,

      segmentedControl.topAnchor.constraint(equalTo: continueWatchingView.bottomAnchor, constant: 8),
      segmentedControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      segmentedControl.widthAnchor.constraint(equalToConstant: 240),

      searchField.centerYAnchor.constraint(equalTo: segmentedControl.centerYAnchor),
      searchField.leadingAnchor.constraint(equalTo: segmentedControl.trailingAnchor, constant: 12),
      searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

      scrollView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

      errorLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      errorLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
      errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
      errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
    ])

    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    continueWatchingView.onOpenItem = { [weak self] item in self?.openItem(item) }

    NotificationCenter.default.addObserver(self, selector: #selector(storeScanned(_:)),
                                           name: MediaLibraryStore.scannedNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(historyUpdated),
                                           name: .iinaHistoryUpdated, object: nil)

    // Initial render from cached index, then kick off a rescan.
    refresh()
    MediaLibraryStore.shared.rescan()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: Actions

  @objc private func categoryChanged(_ sender: NSSegmentedControl) {
    switch sender.selectedSegment {
    case 0: currentCategory = .movie
    case 1: currentCategory = .tvShow
    case 2: currentCategory = .other
    default: break
    }
    refresh()
  }

  @objc private func searchChanged(_ sender: NSSearchField) {
    currentFilter = sender.stringValue
    refresh()
  }

  @objc private func storeScanned(_ note: Notification) {
    DispatchQueue.main.async { [weak self] in
      if let error = note.userInfo?["error"] as? Error {
        self?.showError(error)
      } else {
        self?.errorLabel.isHidden = true
      }
      self?.refresh()
    }
  }

  @objc private func historyUpdated() {
    DispatchQueue.main.async { [weak self] in self?.refresh() }
  }

  // MARK: Refresh

  /// Re-query the store and reload the grid + continue-watching strip.
  func refresh() {
    let store = MediaLibraryStore.shared
    let cwItems = store.continueWatchingItems()
    // Collapse the continue-watching strip when empty so it doesn't reserve 130pt of blank space.
    continueWatchingHeightConstraint.constant = cwItems.isEmpty ? 0 : 130

    let filter = currentFilter.isEmpty ? nil : currentFilter
    if currentCategory == .tvShow {
      // TV-show category: one representative card per show (collection layer), not per episode.
      let groups = store.tvShowGroups(filter: filter)
      displayedItems = groups.map(\.representative)
      displayedGroupCounts = groups.map(\.episodeCount)
    } else {
      displayedItems = store.items(category: currentCategory, filter: filter)
      displayedGroupCounts = []
    }

    collectionView.reloadData()
    continueWatchingView.update(with: cwItems)
    if displayedItems.isEmpty {
      emptyStateLabel.stringValue = store.isScanning ? "扫描中…" : "没有媒体文件"
      emptyStateLabel.isHidden = false
    } else {
      emptyStateLabel.isHidden = true
    }
  }

  private func showError(_ error: Error) {
    if let mlError = error as? MediaLibraryError {
      switch mlError {
      case .pathNotAccessible:
        errorLabel.stringValue = "媒体库路径不可访问，请确认 NAS 已挂载或在设置中修改路径。"
      case .scanFailed(_, let underlying):
        // Surface the underlying Cocoa I/O error — MediaLibraryError's default
        // localizedDescription swallows it, leaving the user with a useless "错误1". Cached items
        // are preserved on rescan failure, so tell the user the library is still usable.
        errorLabel.stringValue = "扫描目录时出错（缓存仍可用）：\(underlying.localizedDescription)"
      }
    } else {
      errorLabel.stringValue = error.localizedDescription
    }
    errorLabel.isHidden = false
    emptyStateLabel.isHidden = true
  }

  // MARK: Open item

  private func openItem(_ item: MediaItem) {
    onOpenItem?(item)
  }

  // MARK: DataSource

  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    return displayedItems.count
  }

  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = collectionView.makeItem(withIdentifier: MediaLibraryViewController.itemIdentifier, for: indexPath) as! MediaItemCollectionViewItem
    if let mediaItem = displayedItems[at: indexPath.item] {
      let idx = indexPath.item
      // TV-show collection mode: display the bare show name + episode-count badge.
      if idx < displayedGroupCounts.count {
        let displayName = mediaItem.tvShowId ?? mediaItem.cleanedName
        item.configure(with: mediaItem,
                       ignorePath: PlayerCore.activeOrNew.ignorePathInWatchLaterConfig,
                       displayName: displayName,
                       episodeCount: displayedGroupCounts[idx])
      } else {
        item.configure(with: mediaItem, ignorePath: PlayerCore.activeOrNew.ignorePathInWatchLaterConfig)
      }
    }
    return item
  }

  // MARK: Delegate

  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let idx = indexPaths.first?.item, let item = displayedItems[at: idx] else { return }
    collectionView.deselectItems(at: indexPaths)
    if item.category == .tvShow, item.tvShowId != nil {
      onSelectTVShow?(item)
    } else {
      openItem(item)
    }
  }
}
