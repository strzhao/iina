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
    // Default the window to the main screen's visible frame so the grid fills the screen on
    // first open — the old fixed 1000×680 felt cramped on large displays. The autosave name is
    // versioned (v3) so this larger default takes effect even for users who still had a small
    // frame cached under v1/v2; from then on AppKit remembers their manual adjustments as usual.
    let defaultFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let window = NSWindow(
      contentRect: defaultFrame,
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("media_library.window.title", comment: "Media Library")
    window.setFrameAutosaveName("MediaLibraryWindow_v3")
    window.minSize = NSMakeSize(720, 480)
    super.init(window: window)

    // Playback open handler: open in the active/new player window (relies on watch-later resume).
    viewController.onOpenItem = { item in
      PlayerCore.activeOrNew.openURL(item.url)
    }
    // TV show selection handler: open the whole show as an mpv playlist via `openURLs`, with the
    // continue-watching episode (or first if none) placed first so mpv opens it and the rest are
    // appended. The user switches episodes via IINA's existing playlist panel (OSC toolbar button)
    // — we do NOT show any floating/sidebar panel here. Resume position is supplied by mpv
    // `resumePlayback` (reads watch-later) on the first (continue-watching) episode — no manual
    // seek, which would race with openURL's async file load (plan-reviewer B1).
    viewController.onSelectTVShow = { item in
      guard let tvShowId = item.tvShowId else {
        PlayerCore.activeOrNew.openURL(item.url)
        return
      }
      let store = MediaLibraryStore.shared
      let episodes = store.tvShowEpisodes(tvShowId: tvShowId)
      guard !episodes.isEmpty else {
        PlayerCore.activeOrNew.openURL(item.url)
        return
      }
      // Continue-watching episode first: mpv opens it and `resumePlayback` auto-resumes; the rest
      // are appended to the mpv playlist for the user to switch via the existing playlist panel.
      let target = store.lastWatchedEpisode(tvShowId: tvShowId) ?? episodes[0]
      let ordered = [target] + episodes.filter { $0.url != target.url }
      PlayerCore.activeOrNew.openURLs(ordered.map { $0.url })
    }

    contentViewController = viewController
    // Force the content area to the screen's visible size. Assigning contentViewController
    // otherwise adopts the VC's loadView() placeholder frame (1000×680), shrinking the window
    // back down regardless of the contentRect passed to NSWindow above. Done after the VC is set
    // and after setFrameAutosaveName so a fresh autosave name records this larger default.
    window.setContentSize(defaultFrame.size)
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
}
