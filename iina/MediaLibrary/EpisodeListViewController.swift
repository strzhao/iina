//
//  EpisodeListViewController.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// Lists all episodes of a TV show (sorted by episode number) and highlights the last-watched one.
///
/// Double-click (or single-click select) opens the episode for playback via `onOpenEpisode`.
class EpisodeListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

  private let episodes: [MediaItem]
  private let lastWatched: MediaItem?
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()

  /// Called when the user opens an episode (double-click).
  var onOpenEpisode: ((MediaItem) -> Void)?

  init(episodes: [MediaItem], lastWatched: MediaItem?) {
    self.episodes = episodes
    self.lastWatched = lastWatched
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 560))

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.style = .inset
    tableView.headerView = nil
    tableView.rowHeight = 40
    tableView.backgroundColor = .clear
    tableView.allowsMultipleSelection = false
    tableView.target = self
    tableView.doubleAction = #selector(doubleClick(_:))

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Episode"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    container.addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])

    tableView.dataSource = self
    tableView.delegate = self

    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Select & scroll to the last-watched episode.
    if let last = lastWatched,
       let idx = episodes.firstIndex(where: { $0.url == last.url }) {
      tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
      tableView.scrollRowToVisible(idx)
    }
  }

  // MARK: Actions

  @objc private func doubleClick(_ sender: NSTableView) {
    let row = sender.clickedRow
    guard row >= 0, row < episodes.count else { return }
    onOpenEpisode?(episodes[row])
  }

  // MARK: DataSource

  func numberOfRows(in tableView: NSTableView) -> Int { episodes.count }

  // MARK: Delegate

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cellID = NSUserInterfaceItemIdentifier("EpisodeCell")
    let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
      ?? NSTableCellView()
    cell.identifier = cellID

    let episode = episodes[row]
    let title: String
    if let ep = episode.episodeNumber {
      title = "第 \(ep) 集  ·  \(episode.cleanedName)"
    } else {
      title = episode.cleanedName
    }

    // Build a text field if needed.
    if cell.textField == nil {
      let tf = NSTextField(labelWithString: "")
      tf.font = NSFont.systemFont(ofSize: 13)
      tf.textColor = NSColor.labelColor
      tf.lineBreakMode = .byTruncatingTail
      cell.addSubview(tf)
      tf.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      cell.textField = tf
    }
    cell.textField?.stringValue = title

    // Highlight last-watched row.
    let isLastWatched = (lastWatched?.url == episode.url)
    cell.textField?.font = isLastWatched
      ? NSFont.systemFont(ofSize: 13, weight: .semibold)
      : NSFont.systemFont(ofSize: 13)
    cell.layer?.backgroundColor = isLastWatched
      ? NSColor.selectedControlColor.withAlphaComponent(0.35).cgColor
      : NSColor.clear.cgColor
    cell.wantsLayer = true

    // Tool tip indicating last-watched.
    cell.toolTip = isLastWatched ? "上次观看的集" : nil
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    // Single-click does not auto-open; double-click opens. Selection only highlights.
  }
}
