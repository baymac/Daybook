import Foundation
import SQLite3

@main
struct StoreTests {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DaybookStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try ActivityStore(url: url)
    func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }
    try store.append(
      bundleID: "test.editor", appName: "Editor", domain: nil, start: date(0), end: date(100))
    try store.append(
      bundleID: "test.browser", appName: "Browser", domain: "example.com", start: date(50),
      end: date(150))
    let clipped = try store.sessions(from: date(25), to: date(125))
    assert(clipped.count == 2)
    assert(
      clipped.reduce(0) { $0 + $1.duration } == 100,
      "Overlapping intervals must never inflate totals")
    assert(clipped[0].start == date(25) && clipped[1].end == date(125))
    let boundarySessions = try store.sessions(from: date(150), to: date(160))
    assert(boundarySessions.isEmpty)
    do {
      try store.append(bundleID: "test", appName: "Test", domain: nil, start: date(5), end: date(5))
      assertionFailure("Invalid interval accepted")
    } catch StoreError.invalidInterval {}
    try store.setCategory(.productivity, for: "example.com")
    let usage = try store.usage(from: date(0), to: date(200))
    assert(usage.first?.duration == 100)
    assert(usage.first(where: { $0.id == "example.com" })?.category == .productivity)

    let sourceURL = root.appendingPathComponent("timecard.sqlite")
    var source: OpaquePointer?
    assert(sqlite3_open(sourceURL.path, &source) == SQLITE_OK)
    let sql =
      "CREATE TABLE session(id INTEGER PRIMARY KEY,bundle_id TEXT,domain TEXT,start REAL,end REAL,source TEXT,device TEXT); INSERT INTO session VALUES(1,'test.import',NULL,1790000100,1790000200,'screentime','MacBook Pro'),(2,'test.phone',NULL,1790000200,1790000300,'screentime','iPhone'),(3,'test.unknown',NULL,1790000300,1790000400,'screentime',NULL);"
    assert(sqlite3_exec(source, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(source)
    let sourceBefore = try Data(contentsOf: sourceURL)
    let firstImport = try store.importTimecard(from: sourceURL)
    let secondImport = try store.importTimecard(from: sourceURL)
    assert(firstImport == 1 && secondImport == 0, "Imports must be repeatable without duplication")
    let sourceAfter = try Data(contentsOf: sourceURL)
    assert(sourceBefore == sourceAfter, "Source database was modified")
    let all = try store.sessions(from: date(0), to: date(500))
    assert(all.reduce(0) { $0 + $1.duration } == 200)
    assert(!all.contains { $0.bundleID == "test.phone" || $0.bundleID == "test.unknown" })

    let reopened = try ActivityStore(url: url)
    assert(reopened.category(for: "example.com") == .productivity)
    try store.append(
      bundleID: "test.csv", appName: "=DANGER,\"quoted\"", domain: nil, start: date(500),
      end: date(510))
    let csv = try store.exportCSV(from: date(500), to: date(510))
    assert(csv.contains("\"'=DANGER,\"\"quoted\"\"\""))
    for i in 0..<4 {
      try store.append(
        bundleID: "test.checkpoint", appName: "Checkpoint", domain: nil,
        start: date(1_000 + Double(i) * 15), end: date(1_015 + Double(i) * 15))
    }
    let checkpointUsage = try store.usage(from: date(1_000), to: date(1_060))
    assert(
      checkpointUsage.count == 1 && checkpointUsage[0].visits == 1
        && checkpointUsage[0].duration == 60)
    try store.append(
      bundleID: "test.browser", appName: "Browser", domain: "one.test", start: date(1_100),
      end: date(1_110))
    try store.append(
      bundleID: "test.browser", appName: "Browser", domain: "two.test", start: date(1_110),
      end: date(1_120))
    try store.append(
      bundleID: "test.browser", appName: "Browser", domain: "one.test", start: date(1_120),
      end: date(1_130))
    let domainUsage = try store.usage(from: date(1_100), to: date(1_130))
    assert(
      domainUsage.first(where: { $0.id == "one.test" })?.visits == 2,
      "A domain switch must preserve separate visits")
    assert(domainUsage.first(where: { $0.id == "two.test" })?.duration == 10)
    // Inserting a missing checkpoint between two equal neighbors joins both.
    try store.append(
      bundleID: "test.bridge", appName: "Bridge", domain: nil, start: date(1_200), end: date(1_210))
    try store.append(
      bundleID: "test.bridge", appName: "Bridge", domain: nil, start: date(1_220), end: date(1_230))
    try store.append(
      bundleID: "test.bridge", appName: "Bridge", domain: nil, start: date(1_210), end: date(1_220))
    let bridged = try store.usage(from: date(1_200), to: date(1_230))
    assert(bridged.count == 1 && bridged[0].visits == 1 && bridged[0].duration == 30)
    let categoryCases: [(String, Category)] = [
      ("com.apple.dt.Xcode", .productivity), ("com.apple.Terminal", .productivity),
      ("com.microsoft.Excel", .productivity), ("com.figma.Desktop", .productivity),
      ("com.tinyspeck.slackmacgap", .communication), ("com.apple.mail", .communication),
      ("com.apple.MobileSMS", .communication),
      ("com.microsoft.teams2", .communication), ("us.zoom.xos", .communication),
      ("com.spotify.client", .music), ("com.apple.finder", .utilities),
      ("com.1password.1password", .utilities), ("org.ankiweb.dtop", .learning),
      ("WWW.Reddit.COM.", .social), ("old.reddit.com", .social),
      ("https://www.youtube.com/watch?v=test", .entertainment),
      ("docs.python.org", .learning), ("developer.mozilla.org", .learning),
      ("docs.google.com", .productivity), ("meet.google.com", .communication),
      ("notreddit.com", .other), ("reddit.com.attacker.test", .other),
      ("com.unknown.code.collector", .other), ("com.unknown.terminal", .other),
      ("docs.unknown.test", .other), ("myx.com", .other), ("unknown.test", .other),
      ("netbanking.hdfcbank.com", .finance), ("kite.zerodha.com", .finance),
      ("com.cmuxterm.app", .productivity), ("org.p0deje.Maccy", .utilities),
      ("org.pgadmin.pgadmin4", .productivity), ("developer.apple.wwdc-release", .learning),
      ("com.shazam.mac.shazam", .entertainment), ("local.daybook.mac", .utilities),
      ("test.cmuxterm.app", .other), ("org.unknown.maccy-helper", .other),
      ("amazon.in", .shopping), ("www.flipkart.com", .shopping),
      ("news.ycombinator.com", .news), ("reuters.com", .news),
      ("notamazon.com", .other), ("hdfcbank.com.bad.test", .other),
    ]
    for (key, expected) in categoryCases {
      assert(store.category(for: key) == expected, "Unexpected category for \(key)")
    }
    try store.setCategory(.learning, for: "WWW.YouTube.com.")
    assert(
      store.category(for: "youtube.com") == .learning,
      "Custom rule must beat automatic rule and normalize host")
    assert(store.categoryOrigin(for: "www.youtube.com") == "Custom rule")
    assert(store.categoryOrigin(for: "reuters.com") == "Built-in rule")
    assert(store.categoryOrigin(for: "unknown.test") == "Other (no matching rule)")
    try store.setCategory(.productivity, for: "test.classified-browser")
    try store.append(
      bundleID: "test.classified-browser", appName: "Browser", domain: "reddit.com",
      start: date(1_300), end: date(1_310))
    try store.append(
      bundleID: "test.classified-browser", appName: "Browser", domain: "unknown.test",
      start: date(1_310), end: date(1_320))
    let classifiedBrowser = try store.usage(from: date(1_300), to: date(1_320))
    assert(
      classifiedBrowser.first(where: { $0.id == "reddit.com" })?.category == .social,
      "Domain classification must precede browser app rule")
    assert(
      classifiedBrowser.first(where: { $0.id == "unknown.test" })?.category == .other,
      "Unknown website cannot inherit browser productivity")
    var legacyConnection: OpaquePointer?
    assert(sqlite3_open(url.path, &legacyConnection) == SQLITE_OK)
    assert(
      sqlite3_exec(
        legacyConnection,
        "INSERT INTO categories(key,category) VALUES('legacy.app','work'),('WWW.LegacyHost.COM.','work')",
        nil, nil, nil) == SQLITE_OK)
    sqlite3_close(legacyConnection)
    assert(
      store.category(for: "legacy.app") == .productivity, "Legacy work rules must remain meaningful"
    )
    let withRules = try ActivityStore(url: url)
    assert(
      withRules.category(for: "www.youtube.com") == .learning, "Custom rules must survive relaunch")
    assert(
      withRules.category(for: "legacyhost.com") == .productivity,
      "Existing mixed-case host rules must migrate")
    // Seed the old schema to exercise provenance migration without touching
    // private activity. Its existing rows must remain legacy and immutable.
    let idleURL = root.appendingPathComponent("idle.sqlite")
    var oldDatabase: OpaquePointer?
    assert(sqlite3_open(idleURL.path, &oldDatabase) == SQLITE_OK)
    assert(
      sqlite3_exec(
        oldDatabase,
        "CREATE TABLE activity(id INTEGER PRIMARY KEY,bundle_id TEXT NOT NULL,app_name TEXT NOT NULL,domain TEXT,start REAL NOT NULL,end REAL NOT NULL); INSERT INTO activity VALUES(1,'legacy.app','Legacy',NULL,1790000300,1790000400)",
        nil, nil, nil) == SQLITE_OK)
    sqlite3_close(oldDatabase)
    let idleStore = try ActivityStore(url: idleURL)
    // Same identity and shared boundary as imported history must not merge
    // across provenance, or idle cleanup would erase imported time.
    try idleStore.append(
      bundleID: "test.import", appName: "import", domain: nil, start: date(50), end: date(100))
    let idleImported = try idleStore.importTimecard(from: sourceURL)
    assert(idleImported == 1)
    let provenanceBoundary = try idleStore.sessions(from: date(50), to: date(200))
    assert(provenanceBoundary.count == 2)
    try idleStore.removeLiveActivity(from: date(0), to: date(500))
    let historyAfterIdle = try idleStore.sessions(from: date(0), to: date(500))
    assert(
      historyAfterIdle.count == 2 && historyAfterIdle.reduce(0) { $0 + $1.duration } == 200,
      "Idle removal must preserve imported and migrated legacy history")
    assert(!historyAfterIdle.contains { $0.start == date(50) })
    try idleStore.append(
      bundleID: "test.split", appName: "Split", domain: "one.test", start: date(1_000),
      end: date(1_100))
    try idleStore.removeLiveActivity(from: date(1_030), to: date(1_070))
    let split = try idleStore.sessions(from: date(1_000), to: date(1_100))
    assert(
      split.count == 2 && split[0].start == date(1_000) && split[0].end == date(1_030)
        && split[1].start == date(1_070) && split[1].end == date(1_100))
    try idleStore.removeLiveActivity(from: date(1_030), to: date(1_070))
    let repeatedSplit = try idleStore.sessions(from: date(1_000), to: date(1_100))
    assert(
      repeatedSplit.reduce(0) { $0 + $1.duration } == 60,
      "Repeated idle correction must be idempotent")
    try idleStore.append(
      bundleID: "test.full", appName: "Full", domain: nil, start: date(1_200), end: date(1_250))
    try idleStore.append(
      bundleID: "test.untouched", appName: "Untouched", domain: nil, start: date(1_300),
      end: date(1_350))
    try idleStore.removeLiveActivity(from: date(1_190), to: date(1_260))
    let fullyRemoved = try idleStore.sessions(from: date(1_190), to: date(1_260))
    let untouched = try idleStore.sessions(from: date(1_300), to: date(1_350))
    assert(fullyRemoved.isEmpty && untouched.count == 1 && untouched[0].duration == 50)
    try idleStore.append(
      bundleID: "test.refill", appName: "Refill", domain: nil, start: date(1_020), end: date(1_080))
    let refilled = try idleStore.sessions(from: date(1_000), to: date(1_100))
    assert(
      refilled.reduce(0) { $0 + $1.duration } == 100,
      "Refilling removed time must still subtract occupied intervals")
    try idleStore.removeLiveActivity(from: date(1_000), to: date(1_010))
    try idleStore.removeLiveActivity(from: date(1_090), to: date(1_100))
    let trimmed = try idleStore.sessions(from: date(1_000), to: date(1_100))
    assert(
      trimmed.first?.start == date(1_010) && trimmed.last?.end == date(1_090)
        && trimmed.reduce(0) { $0 + $1.duration } == 80)
    print(
      "Store tests passed: overlap accounting, clipping, categories and boundary rules, read-only deduplicated Mac import, persistence, CSV escaping, checkpoint coalescing."
    )
  }
}
