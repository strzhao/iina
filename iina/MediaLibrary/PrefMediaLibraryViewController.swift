//
//  PrefMediaLibraryViewController.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Cocoa

/// Preference pane for the media library: configure the NAS root path and clear thumbnail cache.
///
/// Built in code (no xib) to minimize project-file churn. Conforms to `PreferenceWindowEmbeddable`.
class PrefMediaLibraryViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    // No xib; view is built in `loadView`. Return a unique name for sidebar matching only.
    return NSNib.Name("PrefMediaLibraryViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.media_library", comment: "Media Library")
  }

  var preferenceTabImage: NSImage {
    return .sf("rectangle.stack", withConfiguration: symbolConfiguration)!
  }

  // MARK: Subviews

  private let pathControl = NSPathControl()
  private let chooseButton = NSButton(title: "选择…", target: nil, action: nil)
  private let clearCacheButton = NSButton(title: "清除缩略图缓存", target: nil, action: nil)
  private let cacheSizeLabel = NSTextField(labelWithString: "")

  // MARK: Load view (code)

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))

    // Section: root path
    let sectionTitle = sectionTitleLabel("媒体库根目录")
    let pathRow = NSView()
    pathControl.translatesAutoresizingMaskIntoConstraints = false
    pathControl.url = URL(fileURLWithPath: MediaLibraryStore.shared.rootPath, isDirectory: true)
    pathControl.pathStyle = .standard
    chooseButton.translatesAutoresizingMaskIntoConstraints = false
    chooseButton.bezelStyle = .rounded
    chooseButton.target = self
    chooseButton.action = #selector(chooseFolder(_:))
    pathRow.addSubview(pathControl)
    pathRow.addSubview(chooseButton)

    let hintLabel = hintLabelView("包含「电影」「电视剧」「其它」三个子目录的根路径（默认 NAS 挂载点）。")

    NSLayoutConstraint.activate([
      pathControl.leadingAnchor.constraint(equalTo: pathRow.leadingAnchor),
      pathControl.centerYAnchor.constraint(equalTo: pathRow.centerYAnchor),
      pathControl.heightAnchor.constraint(equalToConstant: 24),
      chooseButton.leadingAnchor.constraint(equalTo: pathControl.trailingAnchor, constant: 8),
      chooseButton.trailingAnchor.constraint(equalTo: pathRow.trailingAnchor),
      chooseButton.centerYAnchor.constraint(equalTo: pathRow.centerYAnchor),
      pathRow.heightAnchor.constraint(equalToConstant: 28),
    ])

    // Section: cache
    let cacheSectionTitle = sectionTitleLabel("缩略图缓存")
    cacheSizeLabel.translatesAutoresizingMaskIntoConstraints = false
    cacheSizeLabel.font = NSFont.systemFont(ofSize: 12)
    cacheSizeLabel.textColor = NSColor.secondaryLabelColor
    clearCacheButton.translatesAutoresizingMaskIntoConstraints = false
    clearCacheButton.bezelStyle = .rounded
    clearCacheButton.target = self
    clearCacheButton.action = #selector(clearCache(_:))

    // Stack
    let stack = NSStackView(views: [sectionTitle, pathRow, hintLabel, cacheSectionTitle, cacheSizeLabel, clearCacheButton])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      stack.widthAnchor.constraint(equalToConstant: 480),
    ])

    self.view = container
    updateCacheSize()
  }

  // MARK: Actions

  @objc private func chooseFolder(_ sender: Any) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "选择"
    if let current = pathControl.url { panel.directoryURL = current }
    panel.beginSheetModal(for: view.window!) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.applyRootPath(url)
    }
  }

  @objc private func clearCache(_ sender: Any) {
    MediaThumbnailer.clearCache()
    updateCacheSize()
  }

  // MARK: Helpers

  private func applyRootPath(_ url: URL) {
    let path = url.path
    UserDefaults.standard.set(path, forKey: "mediaLibraryRootPath")
    pathControl.url = url
    MediaLibraryStore.shared.rescan()
  }

  private func updateCacheSize() {
    let dir = MediaThumbnailer.cacheDirectoryURL()
    let size = directorySize(at: dir)
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useKB]
    formatter.countStyle = .file
    cacheSizeLabel.stringValue = "当前缓存大小：\(formatter.string(fromByteCount: size))"
  }

  private func directorySize(at url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
        total += Int64(size)
      }
    }
    return total
  }

  private func sectionTitleLabel(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    label.textColor = NSColor.labelColor
    return label
  }

  private func hintLabelView(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = NSFont.systemFont(ofSize: 11)
    label.textColor = NSColor.secondaryLabelColor
    label.isSelectable = false
    return label
  }
}
