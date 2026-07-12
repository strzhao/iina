//
//  MediaLibraryError.swift
//  iina
//
//  Created by autopilot on 11/7/2026.
//  Copyright © 2026 IINA. All rights reserved.
//

import Foundation

/// Errors raised by the media library scanner/store.
enum MediaLibraryError: Error {
  /// The scan root path does not exist or is not readable.
  case pathNotAccessible(url: URL)
  /// An I/O error occurred during scanning.
  case scanFailed(url: URL, underlying: Error)
}
