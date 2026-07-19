//
//  IINALoggerJSONLTests.swift
//  iinaTests
//
//  Tests for Logger <-> IINALogWriter integration via the testing seams.
//  Covers: level filtering, meta passthrough, configure/reset idempotency.
//
//  TSan note (patterns.md [2026-07-18]): all seams read/write jsonlMinLevel inside
//  jsonlQueue.sync, so there is no background write to a static var — these tests are race-free.
//

import XCTest
@testable import IINA

final class IINALoggerJSONLTests: XCTestCase {

  private var tmpDir: String!

  override func setUp() {
    super.setUp()
    tmpDir = NSTemporaryDirectory() + "iina-logger-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
      atPath: tmpDir, withIntermediateDirectories: true, attributes: nil)
  }

  override func tearDown() {
    Logger.resetForTesting()
    try? FileManager.default.removeItem(atPath: tmpDir)
    tmpDir = nil
    super.tearDown()
  }

  private func readJSONL() -> [[String: Any]] {
    let path = "\(tmpDir!)/\(IINALogConfig.currentLogFileName)"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return content.split(separator: "\n").compactMap { line -> [String: Any]? in
      let s = String(line)
      guard !s.isEmpty,
            let data = s.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      return json
    }
  }

  func testJSONLRespectsLevelFilter() {
    Logger.configureForTesting(logsDir: tmpDir, level: .warning)
    Logger.log("debug msg", level: .debug, subsystem: .general)
    Logger.log("warn msg", level: .warning, subsystem: .general)
    Logger._syncFlush()

    let lines = readJSONL()
    XCTAssertEqual(lines.count, 1, "debug must be filtered out at warning min level")
    XCTAssertEqual(lines[0]["msg"] as? String, "warn msg")
  }

  func testConfigureForTestingSetsMinLevel() {
    Logger.configureForTesting(logsDir: tmpDir, level: .error)
    XCTAssertEqual(Logger._currentMinLevel, .error)
  }

  func testResetForTestingClearsState() {
    Logger.configureForTesting(logsDir: tmpDir, level: .warning)
    Logger.resetForTesting()
    XCTAssertNil(Logger._currentMinLevel)
  }

  func testMetaFieldWrittenViaMetaOverload() {
    Logger.configureForTesting(logsDir: tmpDir, level: .debug)
    Logger.log("with meta", level: .warning, subsystem: .general,
               meta: ["err": "E001", "host": "nas"])
    Logger._syncFlush()

    let lines = readJSONL()
    XCTAssertEqual(lines.count, 1)
    let meta = lines[0]["meta"] as? [String: Any]
    XCTAssertEqual(meta?["err"] as? String, "E001")
    XCTAssertEqual(meta?["host"] as? String, "nas")
  }

  func testConfigureIsIdempotent() {
    Logger.configureForTesting(logsDir: tmpDir, level: .warning)
    Logger.configureForTesting(logsDir: tmpDir, level: .warning)  // must not crash
    Logger.log("x", level: .warning, subsystem: .general)
    Logger._syncFlush()
    XCTAssertEqual(readJSONL().count, 1)
  }

  func testDisabledWhenLevelNil() {
    // level == nil means channel off: nothing should be written.
    Logger.configureForTesting(logsDir: tmpDir, level: nil)
    Logger.log("should be dropped", level: .error, subsystem: .general)
    Logger._syncFlush()
    XCTAssertEqual(readJSONL().count, 0)
  }
}
