//
//  IINALogWriterTests.swift
//  iinaTests
//
//  Tests for IINALogWriter (pure IO: JSONL format / rotation / pruning / fault tolerance).
//

import XCTest
@testable import IINA

final class IINALogWriterTests: XCTestCase {

  private var tmpDir: String!

  override func setUp() {
    super.setUp()
    tmpDir = NSTemporaryDirectory() + "iina-logwriter-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
      atPath: tmpDir, withIntermediateDirectories: true, attributes: nil)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: tmpDir)
    tmpDir = nil
    super.tearDown()
  }

  private func makeWriter(file: String = IINALogConfig.currentLogFileName) -> IINALogWriter {
    IINALogWriter(logsDir: tmpDir, currentPath: "\(tmpDir!)/\(file)")
  }

  /// Parse every non-empty line of the current jsonl file into JSON dictionaries.
  private func readJSONL(_ name: String = IINALogConfig.currentLogFileName) -> [[String: Any]] {
    let path = "\(tmpDir!)/\(name)"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return content.split(separator: "\n").compactMap { line -> [String: Any]? in
      let s = String(line)
      guard !s.isEmpty,
            let data = s.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      return json
    }
  }

  func testAppendWritesValidJSONL() {
    let writer = makeWriter()
    writer.ensureCurrentFile()
    writer.append(level: .warning, subsystem: "test", msg: "hello",
                  meta: ["k": "v"], file: nil, line: nil)

    let lines = readJSONL()
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(lines[0]["level"] as? String, "warning")
    XCTAssertEqual(lines[0]["subsystem"] as? String, "test")
    XCTAssertEqual(lines[0]["msg"] as? String, "hello")
    XCTAssertNotNil(lines[0]["ts"] as? String)
    XCTAssertEqual((lines[0]["meta"] as? [String: Any])?["k"] as? String, "v")
  }

  func testAllLevelsEncodeDescription() {
    let writer = makeWriter()
    writer.ensureCurrentFile()
    writer.append(level: .verbose, subsystem: "s", msg: "1", meta: nil, file: nil, line: nil)
    writer.append(level: .debug, subsystem: "s", msg: "2", meta: nil, file: nil, line: nil)
    writer.append(level: .warning, subsystem: "s", msg: "3", meta: nil, file: nil, line: nil)
    writer.append(level: .error, subsystem: "s", msg: "4", meta: nil, file: nil, line: nil)

    let levels = readJSONL().compactMap { $0["level"] as? String }
    XCTAssertEqual(levels, ["verbose", "debug", "warning", "error"])
  }

  func testFileAndLineCapturedInMeta() {
    let writer = makeWriter()
    writer.ensureCurrentFile()
    writer.append(level: .warning, subsystem: "s", msg: "x",
                  meta: nil, file: "/some/path/Foo.swift", line: 42)

    let meta = readJSONL()[0]["meta"] as? [String: Any]
    XCTAssertEqual(meta?["file"] as? String, "Foo.swift")
    XCTAssertEqual(meta?["line"] as? Int, 42)
  }

  func testRotationProducesArchive() {
    let writer = makeWriter()
    writer.ensureCurrentFile()
    // Write ~5.4 MiB (> 5 MiB threshold) to force one rotation.
    let big = String(repeating: "x", count: 1024)
    for _ in 0..<5_500 {
      writer.append(level: .error, subsystem: "test", msg: big, meta: nil, file: nil, line: nil)
    }

    let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir!)) ?? []
    let archives = entries.filter { $0.hasPrefix("iina-") && $0.hasSuffix(".jsonl") }
    XCTAssertFalse(archives.isEmpty, "rotation should produce at least one iina-<ts>.jsonl archive")
  }

  func testPruneArchivesEnforcesMaxCount() throws {
    let fm = FileManager.default
    // Create 35 archive files with strictly increasing mtimes so pruning has a stable order.
    for i in 0..<35 {
      let name = String(format: "iina-2026010%d-00000%02d.jsonl", i / 10, i)
      let path = "\(tmpDir!)/\(name)"
      try "dummy".write(toFile: path, atomically: true, encoding: .utf8)
      let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i * 60))
      try? fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    let writer = makeWriter()
    writer.pruneArchives()

    let remaining = try fm.contentsOfDirectory(atPath: tmpDir!)
      .filter { $0.hasPrefix("iina-") && $0.hasSuffix(".jsonl") }
    XCTAssertLessThanOrEqual(remaining.count, IINALogConfig.retainMaxArchives,
                             "archive count must be <= retainMaxArchives after prune")
  }

  func testAppendResilientToInvalidPath() {
    // Pointing at an unreachable deep path must NOT crash; the writer degrades silently.
    let badDir = "/dev/null/nonexistent-\(UUID().uuidString)"
    let writer = IINALogWriter(logsDir: badDir, currentPath: "\(badDir)/iina.jsonl")
    writer.ensureCurrentFile()
    writer.append(level: .error, subsystem: "x", msg: "should not crash",
                  meta: nil, file: nil, line: nil)
    // Reaching here without a crash is the pass condition.
    XCTAssertTrue(true)
  }

  func testPermissionsAreTight() {
    let writer = makeWriter()
    writer.ensureCurrentFile()
    let fm = FileManager.default
    let dirAttrs = try? fm.attributesOfItem(atPath: tmpDir!)
    let fileAttrs = try? fm.attributesOfItem(atPath: "\(tmpDir!)/\(IINALogConfig.currentLogFileName)")
    let dirPerm = ((dirAttrs?[.posixPermissions] as? NSNumber)?.uintValue) ?? 0
    let filePerm = ((fileAttrs?[.posixPermissions] as? NSNumber)?.uintValue) ?? 0
    XCTAssertEqual(dirPerm, IINALogConfig.dirPermissions, "logs dir must be 0700")
    XCTAssertEqual(filePerm, IINALogConfig.filePermissions, "log file must be 0600")
  }
}
