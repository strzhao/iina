//
//  MediaLibraryWindowController.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// Independent window controller for the media library, built in code (no xib), mirroring
/// `HistoryWindowController`'s construction pattern.
class MediaLibraryWindowController: NSWindowController {

  private let viewController = MediaLibraryViewController()

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("media_library.window.title", comment: "Media Library")
    window.setFrameAutosaveName("MediaLibraryWindow")
    window.minSize = NSMakeSize(720, 480)
    super.init(window: window)

    // Playback open handler: open in the active/new player window (relies on watch-later resume).
    viewController.onOpenItem = { item in
      PlayerCore.activeOrNew.openURL(item.url)
    }
    // TV show selection handler: push the episode list as a sheet/child VC.
    viewController.onSelectTVShow = { [weak self] item in
      self?.showEpisodeList(for: item)
    }

    contentViewController = viewController
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  override func showWindow(_ sender: Any?) {
    // Bring to front if already open.
    if !window!.isVisible {
      window?.center()
    }
    super.showWindow(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Reload library data from the store. Called when the window is reopened so newly added
  /// media surfaces without restarting the app.
  func refresh() {
    viewController.refresh()
  }

  // MARK: Episode list

  private func showEpisodeList(for item: MediaItem) {
    guard let tvShowId = item.tvShowId else { return }
    let episodes = MediaLibraryStore.shared.tvShowEpisodes(tvShowId: tvShowId)
    let lastWatched = MediaLibraryStore.shared.lastWatchedEpisode(tvShowId: tvShowId)
    let episodeVC = EpisodeListViewController(episodes: episodes, lastWatched: lastWatched)
    episodeVC.onOpenEpisode = { ep in
      PlayerCore.activeOrNew.openURL(ep.url)
    }
    let panel = NSPanel(contentViewController: episodeVC)
    panel.title = item.cleanedName
    panel.styleMask = [.titled, .closable, .resizable]
    panel.setFrame(NSRect(x: 0, y: 0, width: 480, height: 560), display: true)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.center()
    window!.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
  }
}
