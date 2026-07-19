//
//  main.swift
//  iina-cli
//
//  Created by Collider LI on 6/12/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

// === Diagnostic subcommand dispatch (git-style) ===
// `iina log|health|cache|version|help` runs a Foundation-only diagnostic that reads files
// directly and never spawns IINA (works even when IINA isn't running). Any other first arg
// falls through to the original launcher logic below.
let _rawArgs = Array(ProcessInfo.processInfo.arguments.dropFirst())
if let _first = _rawArgs.first, IINADiagnosticCLI.isDiagnostic(_first) {
  IINADiagnosticCLI.run(_rawArgs)
  exit(0)
}

guard var execURL = Bundle.main.executableURL else {
  print("Cannot get executable path.")
  exit(1)
}

let currentDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

execURL.resolveSymlinksInPath()

let processInfo = ProcessInfo.processInfo

let iinaPath = execURL.deletingLastPathComponent().appendingPathComponent("IINA").path

guard FileManager.default.fileExists(atPath: iinaPath) else {
  print("Cannot find IINA binary. This command line tool only works in IINA.app bundle.")
  exit(1)
}

let task = Process()
task.launchPath = iinaPath

var keepRunning = false

// Check arguments

var userArgs = Array(processInfo.arguments.dropFirst())

if userArgs.contains(where: { $0 == "--help" || $0 == "-h" }) {
  print(
    """
    Usage: iina-cli [arguments] [files] [-- mpv_option [...]]

    Arguments:
    --mpv-*:
            All mpv options are supported here, except those starting with "--no-".
            Example: --mpv-volume=20 --mpv-resume-playback=no
    --separate-windows | -w:
            Open all files in separate windows.
    --stdin, --no-stdin:
            You may also pipe to stdin directly. Sometimes iina-cli can detect whether
            stdin has file, but sometimes not. Therefore it's recommended to always
            supply --stdin when piping to iina, and --no-stdin when you are not intend
            to use stdin.
    --keep-running:
            Normally iina-cli launches IINA and quits immediately. Supply this option
            if you would like to keep it running until the main application exits.
    --music-mode:
            Enter music mode after opening the media.
    --pip:
            Enter Picture-in-Picture after opening the media. Music mode does not
            support Picture-in-Picture.
    --help | -h:
            Print this message.

    mpv Option:
    Raw mpv options without --mpv- prefix. All mpv options are supported here.
    Example: --volume=20 --no-resume-playback
    """)
  exit(0)
}

if userArgs.contains("--music-mode"), userArgs.contains("--pip") {
  // Music mode does not support Picture-in-Picture. Combining these options is not permitted.
  print("Cannot specify both --music-mode and --pip")
  // Command line usage error.
  exit(EX_USAGE)
}

var isStdin = false
var userSpecifiedStdin = false

for arg in userArgs {
  if arg == "--stdin" {
    isStdin = true
    userSpecifiedStdin = true
  } else if arg == "--no-stdin" {
    isStdin = false
    userSpecifiedStdin = true
  } else if arg == "--" {
    break
  }
}

if (!userSpecifiedStdin) {
  guard let stdin = InputStream(fileAtPath: "/dev/stdin") else {
    print("Cannot open stdin.")
    exit(1)
  }
  stdin.open()
  isStdin = stdin.hasBytesAvailable
}

if let dashIndex = userArgs.firstIndex(of: "--") {
  userArgs.remove(at: dashIndex)
  for i in dashIndex..<userArgs.count {
    let arg = userArgs[i]
    if arg.hasPrefix("--") {
      if arg.hasPrefix("--no-") {
        userArgs[i] = "--mpv-\(arg.dropFirst(5))=no"
      } else {
        userArgs[i] = "--mpv-\(arg.dropFirst(2))"
      }
    }
  }
}

userArgs = userArgs.map { arg in
  if !arg.hasPrefix("-"),
    !Regex.url.matches(arg),
    let encodedFilePath = arg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
    let fileURL = URL(string: encodedFilePath, relativeTo: currentDirURL),
    FileManager.default.fileExists(atPath: fileURL.path) {
    return fileURL.path
  } else if arg == "-w" {
    return "--separate-windows"
  }
  if arg == "--keep-running" {
    keepRunning = true
  }
  return arg
}

// Handle stdin

if isStdin {
  task.standardInput = FileHandle.standardInput
  task.standardOutput = FileHandle.standardOutput
  if !userSpecifiedStdin {
    userArgs.insert("--stdin", at: 0)
  }
} else {
  task.standardOutput = nil
  task.standardError = nil
}

task.arguments = userArgs

func terminateTaskIfRunning() {
  if task.isRunning {
    task.terminate()
  }
}

[SIGTERM, SIGINT].forEach { sig in
  signal(sig) { _ in
    terminateTaskIfRunning()
    exit(1)
  }
}

atexit {
  if isStdin || keepRunning {
    terminateTaskIfRunning()
  }
}

task.launch()

if isStdin || keepRunning {
  task.waitUntilExit()
}

// MARK: - IINA Diagnostic CLI (Foundation-only)
//
// Diagnostic subcommands. Mirrors iina/IINALogConfig.swift path & schema constants
// (⚠️ MIRROR — keep in sync). Reads ~/Library/Logs/IINA/iina.jsonl directly so it works even
// when IINA is not running (contract C4). The CLI is its own target and does NOT link the IINA
// module, so constants are duplicated here on purpose.

enum IINADiagnosticCLI {
  static func isDiagnostic(_ cmd: String) -> Bool {
    // Exact-match reserved words; media files almost always carry extensions so collision is
    // negligible (e.g. `log.mp4` does not match).
    return ["log", "health", "cache", "version", "help"].contains(cmd)
  }

  static func run(_ args: [String]) {
    let cmd = args[0]
    let rest = Array(args.dropFirst())
    switch cmd {
    case "version":
      printVersion()
    case "help", "--help", "-h":
      printDiagnosticHelp()
    case "log":
      runLog(rest)
    case "health":
      runHealth(rest)
    case "cache":
      runCache(rest)
    default:
      fputs("Unknown diagnostic command: \(cmd)\n", stderr)
      exit(2)
    }
  }
}

// MARK: - Path & schema constants (⚠️ MIRROR iina/Logging/IINALogConfig.swift)

// Computed properties (not `let`) — top-level `private let` with a closure initializer crashed
// at first access (SIGSEGV) in this main.swift executable; recomputation here is cheap (µs).
private var iinaLogsDir: String {
  if let env = ProcessInfo.processInfo.environment["IINA_LOG_DIR"], !env.isEmpty {
    return env
  }
  if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
    return libraryURL.appendingPathComponent("Logs").appendingPathComponent("IINA").path
  }
  return "\(NSHomeDirectory())/Library/Logs/IINA"
}
private var iinaCurrentLogPath: String { "\(iinaLogsDir)/iina.jsonl" }
// Schema field names as computed properties — top-level `private let` (even string literals)
// crashed at first access (SIGSEGV) in this main.swift executable, same root cause as iinaLogsDir.
// Using `var` { get } sidesteps the dispatch_once lazy-init path that triggered the crash.
private var iinaLogFieldTimestamp: String { "ts" }
private var iinaLogFieldLevel: String { "level" }
private var iinaLogFieldSubsystem: String { "subsystem" }
private var iinaLogFieldMessage: String { "msg" }
private var iinaLogFieldMeta: String { "meta" }

// MARK: - version / help

private func printVersion() {
  let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
  let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
  print("IINA \(version) Build \(build)")
}

private func printDiagnosticHelp() {
  print("""
  Usage: iina <command> [options]        # diagnostic
         iina [files] [-- mpv_options]   # launch player

  Diagnostic commands:
    iina log path                                Print the iina.jsonl path
    iina log show [--level L] [--subsystem S] [--since Nh/Nm/Nd] [--lines N] [--json]
    iina log tail [--lines N] [--follow]
    iina log grep <pattern> [--level L] [-i]
    iina log clear [--yes]
    iina health                                  Print a JSON health report
    iina cache {list|size|clean [--yes]}         Inspect/clean thumbnail cache
    iina version                                 Print IINA version

  Levels: verbose|debug|warning|error (info/warn are aliases for warning)
  """)
}

// MARK: - log subcommand

private func runLog(_ args: [String]) {
  let subcommand = args.first ?? ""
  let rest = Array(args.dropFirst())
  let opts = parseLogOptions(rest)
  switch subcommand {
  case "path":
    print(iinaCurrentLogPath)
  case "tail":
    cmdLogTail(opts)
  case "show":
    cmdLogShow(opts)
  case "grep":
    let pattern = opts.positional.first ?? ""
    guard !pattern.isEmpty else {
      fputs("Usage: iina log grep <pattern> [--level L] [-i]\n", stderr)
      exit(2)
    }
    cmdLogGrep(pattern: pattern, opts: opts)
  case "clear":
    cmdLogClear(opts)
  default:
    fputs("Usage: iina log <path|show|tail|grep|clear> ...\n", stderr)
    exit(2)
  }
}

private func cmdLogShow(_ opts: LogOptions) {
  let asJSON = opts.json
  let maxLines = opts.lines > 0 ? opts.lines : 0   // 0 = unlimited
  let filtered = filterLogLines(opts: opts, maxLines: maxLines)
  for e in filtered { print(asJSON ? e.raw : formatLogLine(e.raw)) }
}

private func cmdLogTail(_ opts: LogOptions) {
  guard FileManager.default.fileExists(atPath: iinaCurrentLogPath) else {
    fputs("log file not found: \(iinaCurrentLogPath)\n", stderr)
    exit(1)
  }
  let lines = opts.lines > 0 ? opts.lines : 50
  let content = readLogTail(maxBytes: 256 * 1024)
  let allLines = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  for line in Array(allLines.suffix(lines)) {
    print(formatLogLine(line))
  }
  guard opts.follow else { return }
  // --follow: poll every 0.5s for appended bytes
  var lastSize = (try? FileManager.default.attributesOfItem(atPath: iinaCurrentLogPath)[.size] as? Int) ?? 0
  while true {
    Thread.sleep(forTimeInterval: 0.5)
    let nowSize = (try? FileManager.default.attributesOfItem(atPath: iinaCurrentLogPath)[.size] as? Int) ?? lastSize
    if nowSize > lastSize {
      if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: iinaCurrentLogPath)) {
        try? handle.seek(toOffset: UInt64(lastSize))
        let newBytes = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        if let s = String(data: newBytes, encoding: .utf8) {
          for line in s.split(separator: "\n").map(String.init) where !line.isEmpty {
            print(formatLogLine(line))
          }
        }
      }
      lastSize = nowSize
    }
  }
}

private func cmdLogGrep(pattern: String, opts: LogOptions) {
  let asJSON = opts.json
  var filtered = filterLogLines(opts: opts, maxLines: 0)
  let needle = opts.ignoreCase ? pattern.lowercased() : pattern
  filtered = filtered.filter { entry in
    let hay = opts.ignoreCase ? entry.msg.lowercased() : entry.msg
    return hay.contains(needle)
  }
  for e in filtered { print(asJSON ? e.raw : formatLogLine(e.raw)) }
}

private func cmdLogClear(_ opts: LogOptions) {
  let fm = FileManager.default
  guard fm.fileExists(atPath: iinaCurrentLogPath) else {
    print("no log file to clear")
    return
  }
  let confirmed = opts.flags.contains("--yes")
  if !confirmed {
    let isTTY = isatty(fileno(stdout)) != 0
    if isTTY {
      fputs("Clear \(iinaCurrentLogPath)? This archives the current file. Use --yes to skip. [y/N] ", stderr)
      var response = ""
      if let line = readLine() { response = line }
      guard response.lowercased() == "y" || response.lowercased() == "yes" else {
        fputs("aborted\n", stderr)
        exit(1)
      }
    }
  }
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  formatter.timeZone = TimeZone(identifier: "UTC")
  formatter.locale = Locale(identifier: "en_US_POSIX")
  let archivePath = "\(iinaLogsDir)/iina-\(formatter.string(from: Date())).jsonl"
  do {
    try fm.moveItem(atPath: iinaCurrentLogPath, toPath: archivePath)
  } catch {
    fputs("failed to archive log: \(error)\n", stderr)
    exit(1)
  }
  fm.createFile(atPath: iinaCurrentLogPath, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)])
  print("cleared: \(iinaCurrentLogPath) (archived to \(archivePath))")
}

// MARK: - Log option parsing + filtering helpers

private struct LogOptions {
  var lines: Int = 0
  var level: String = ""
  var subsystem: String = ""
  var since: String = ""
  var json: Bool = false
  var follow: Bool = false
  var ignoreCase: Bool = false
  var positional: [String] = []
  var flags: Set<String> = []
}

private func parseLogOptions(_ args: [String]) -> LogOptions {
  var o = LogOptions()
  var i = 0
  while i < args.count {
    let a = args[i]
    switch a {
    case "--json": o.json = true
    case "--follow": o.follow = true
    case "-i", "--ignore-case": o.ignoreCase = true
    case "--yes": o.flags.insert("--yes")
    case "--lines":
      i += 1
      if i < args.count, let n = Int(args[i]) { o.lines = n }
    case "--level":
      i += 1
      if i < args.count { o.level = args[i] }
    case "--subsystem":
      i += 1
      if i < args.count { o.subsystem = args[i] }
    case "--since":
      i += 1
      if i < args.count { o.since = args[i] }
    default:
      if a.hasPrefix("--") { o.flags.insert(a) }
      else { o.positional.append(a) }
    }
    i += 1
  }
  return o
}

private struct LogEntry {
  let raw: String
  let msg: String
}

private func filterLogLines(opts: LogOptions, maxLines: Int) -> [LogEntry] {
  guard let content = try? String(contentsOfFile: iinaCurrentLogPath, encoding: .utf8) else { return [] }
  let allLines = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  var minOrder = -1
  if !opts.level.isEmpty {
    switch opts.level.lowercased() {
    case "verbose": minOrder = 0
    case "debug": minOrder = 1
    case "info", "warn", "warning": minOrder = 2   // IINA has no info; alias to warning
    case "error": minOrder = 3
    default:
      fputs("invalid level '\(opts.level)'; expected verbose|debug|warning|error\n", stderr)
      exit(2)
    }
  }
  let sinceCutoff = parseSinceCutoff(opts.since)
  var result: [LogEntry] = []
  for line in allLines {
    guard let data = line.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      continue   // skip malformed lines (fault tolerance)
    }
    if minOrder >= 0 {
      let levelStr = (json[iinaLogFieldLevel] as? String) ?? ""
      if levelOrder(levelStr) < minOrder { continue }
    }
    if !opts.subsystem.isEmpty {
      let sub = (json[iinaLogFieldSubsystem] as? String) ?? ""
      if sub != opts.subsystem { continue }
    }
    if let cutoff = sinceCutoff {
      let ts = (json[iinaLogFieldTimestamp] as? String) ?? ""
      if let lineDate = parseISO8601(ts), lineDate < cutoff { continue }
    }
    let msg = (json[iinaLogFieldMessage] as? String) ?? ""
    result.append(LogEntry(raw: line, msg: msg))
  }
  if maxLines > 0 {
    result = Array(result.suffix(maxLines))
  }
  return result
}

/// Human-readable summary: `HH:MM:SS.mmm [LEVEL] [subsystem] msg  k=v k=v`
private func formatLogLine(_ raw: String) -> String {
  guard let data = raw.data(using: .utf8),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    return raw   // malformed line returned as-is (fault tolerance)
  }
  let ts = (json[iinaLogFieldTimestamp] as? String) ?? ""
  let level = (json[iinaLogFieldLevel] as? String) ?? "?"
  let subsystem = (json[iinaLogFieldSubsystem] as? String) ?? "?"
  let msg = (json[iinaLogFieldMessage] as? String) ?? ""
  var line = "\(shortTime(ts)) [\(level.uppercased())] [\(subsystem)] \(msg)"
  if let meta = json[iinaLogFieldMeta] as? [String: Any], !meta.isEmpty {
    let pairs = meta.map { (k, v) in "\(k)=\(stringifyMetaValue(v))" }.sorted().joined(separator: " ")
    line += "  " + pairs
  }
  return line
}

private func readLogTail(maxBytes: Int) -> String {
  guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: iinaCurrentLogPath)) else {
    return ""
  }
  defer { try? handle.close() }
  let total = (try? handle.seekToEnd()) ?? 0
  let start = total > UInt64(maxBytes) ? total - UInt64(maxBytes) : 0
  try? handle.seek(toOffset: start)
  let data = (try? handle.readToEnd()) ?? Data()
  return String(data: data, encoding: .utf8) ?? ""
}

/// IINA Level order (mirror Logger.Level): verbose=0, debug=1, warning=2, error=3.
private func levelOrder(_ level: String) -> Int {
  switch level {
  case "verbose": return 0
  case "debug": return 1
  case "warning": return 2
  case "error": return 3
  default: return -1
  }
}

private func parseSinceCutoff(_ since: String) -> Date? {
  guard !since.isEmpty else { return nil }
  let trimmed = since.trimmingCharacters(in: .whitespaces)
  guard let lastChar = trimmed.last, let amount = Int(trimmed.dropLast()) else { return nil }
  let now = Date()
  switch lastChar {
  case "h": return now.addingTimeInterval(-Double(amount) * 3600)
  case "m": return now.addingTimeInterval(-Double(amount) * 60)
  case "d": return now.addingTimeInterval(-Double(amount) * 86400)
  default: return nil
  }
}

private func parseISO8601(_ str: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.date(from: str)
}

private func shortTime(_ ts: String) -> String {
  guard let date = parseISO8601(ts) else { return ts }
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss.SSS"
  return formatter.string(from: date)
}

private func stringifyMetaValue(_ value: Any) -> String {
  if let s = value as? String { return s }
  if let n = value as? NSNumber { return n.stringValue }
  if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
     let s = String(data: data, encoding: .utf8) {
    return s
  }
  return "\(value)"
}

// MARK: - health / cache (stubs; implemented in P2 / P3)

private func runHealth(_ args: [String]) {
  let report = collectHealth()
  if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
     let s = String(data: data, encoding: .utf8) {
    print(s)
  } else {
    fputs("failed to serialize health report\n", stderr)
    exit(1)
  }
}

/// Aggregate a health report by reading disk state (Foundation-only; works when IINA isn't running).
private func collectHealth() -> [String: Any] {
  let fm = FileManager.default
  let bundleID = "com.colliderli.iina"
  let home = NSHomeDirectory()
  let cachesDir = "\(home)/Library/Caches/\(bundleID)"
  let appSupportDir = "\(home)/Library/Application Support/\(bundleID)"
  let logsSessionDir = "\(home)/Library/Logs/\(bundleID)"

  var report: [String: Any] = [:]
  // version (from app bundle Info.plist; "?" when this binary runs standalone, outside IINA.app)
  report["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"
  report["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"

  // log
  let archives = archiveStats()
  report["log"] = [
    "jsonl_path": iinaCurrentLogPath,
    "jsonl_exists": fm.fileExists(atPath: iinaCurrentLogPath),
    "jsonl_size": fileSize(iinaCurrentLogPath),
    "archives": archives.count,
    "archives_total_size": archives.totalSize,
    "iina_log_session_dir": logsSessionDir,
    "iina_log_dir_exists": fm.fileExists(atPath: logsSessionDir),
  ] as [String: Any]

  // cache (thumbnail cache lives under ~/Library/Caches/<bundleID>/)
  let cache = dirStats(cachesDir)
  report["cache"] = [
    "caches_dir": cachesDir,
    "exists": fm.fileExists(atPath: cachesDir),
    "files": cache.files,
    "total_size": cache.totalSize,
  ] as [String: Any]

  // media library
  let indexPlist = "\(appSupportDir)/media_library_index.plist"
  report["media_library"] = [
    "index_plist": indexPlist,
    "exists": fm.fileExists(atPath: indexPlist),
    "size": fileSize(indexPlist),
  ] as [String: Any]

  return report
}

private func fileSize(_ path: String) -> Int {
  ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
}

private func archiveStats() -> (count: Int, totalSize: Int) {
  guard let urls = try? FileManager.default.contentsOfDirectory(
    at: URL(fileURLWithPath: iinaLogsDir),
    includingPropertiesForKeys: [.fileSizeKey]) else {
    return (0, 0)
  }
  let archives = urls.filter { $0.lastPathComponent.hasPrefix("iina-") && $0.pathExtension == "jsonl" }
  let total = archives.reduce(0) {
    $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }
  return (archives.count, total)
}

private func dirStats(_ path: String) -> (files: Int, totalSize: Int) {
  let fm = FileManager.default
  guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                       includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
    return (0, 0)
  }
  var files = 0, total = 0
  for case let url as URL in enumerator {
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
    files += 1
    total += ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }
  return (files, total)
}

private func runCache(_ args: [String]) {
  let sub = args.first ?? ""
  let rest = Array(args.dropFirst())
  switch sub {
  case "list":
    cmdCacheList()
  case "size":
    cmdCacheSize()
  case "clean":
    cmdCacheClean(parseLogOptions(rest))
  default:
    fputs("Usage: iina cache {list|size|clean [--yes]}\n", stderr)
    exit(2)
  }
}

// Thumbnail & IINA runtime caches live under ~/Library/Caches/<bundleID>/.
// Computed property (mirrors the iinaLogsDir fix for top-level `private let`).
private var iinaCachesDir: String {
  "\(NSHomeDirectory())/Library/Caches/com.colliderli.iina"
}

private func cmdCacheList() {
  let fm = FileManager.default
  guard fm.fileExists(atPath: iinaCachesDir) else {
    print("cache dir not found: \(iinaCachesDir)")
    return
  }
  let entries = (try? fm.contentsOfDirectory(atPath: iinaCachesDir)) ?? []
  for e in entries.sorted() {
    let full = "\(iinaCachesDir)/\(e)"
    let isDir = (try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeDirectory
    let stat = dirStats(full)
    print("\(formatBytes(stat.totalSize))\t\(isDir ? "dir " : "file")\t\(e)\t\(stat.files) files")
  }
}

private func cmdCacheSize() {
  let s = dirStats(iinaCachesDir)
  print("\(iinaCachesDir)")
  print("  \(s.files) files, \(formatBytes(s.totalSize))")
}

private func cmdCacheClean(_ opts: LogOptions) {
  let fm = FileManager.default
  guard fm.fileExists(atPath: iinaCachesDir) else {
    print("cache dir not found: \(iinaCachesDir)")
    return
  }
  let confirmed = opts.flags.contains("--yes")
  if !confirmed {
    let isTTY = isatty(fileno(stdout)) != 0
    if isTTY {
      let size = dirStats(iinaCachesDir).totalSize
      fputs("Clear \(iinaCachesDir) (\(formatBytes(size)))? Use --yes to skip. [y/N] ", stderr)
      var response = ""
      if let line = readLine() { response = line }
      guard response.lowercased() == "y" || response.lowercased() == "yes" else {
        fputs("aborted\n", stderr)
        exit(1)
      }
    }
  }
  // Remove every entry under the caches dir (keeps the dir itself). Production caches only;
  // the `-iinaTestDataRoot` XCUI path lives elsewhere and is never touched here.
  let entries = (try? fm.contentsOfDirectory(atPath: iinaCachesDir)) ?? []
  var removed = 0
  for e in entries {
    if (try? fm.removeItem(atPath: "\(iinaCachesDir)/\(e)")) != nil { removed += 1 }
  }
  print("cleared \(removed) entries in \(iinaCachesDir)")
}

private func formatBytes(_ bytes: Int) -> String {
  if bytes < 1024 { return "\(bytes) B" }
  if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
  if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
  return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
}
