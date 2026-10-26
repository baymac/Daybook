import Foundation
import SQLite3

struct ActivitySession: Identifiable, Codable {
  let id: Int64
  let bundleID: String
  let appName: String
  let domain: String?
  let start: Date
  let end: Date
  var mediaKind: MediaKind? = nil
  var usageKey: String {
    var key = (domain ?? bundleID).lowercased()
    if key.hasPrefix("www.") { key = String(key.dropFirst(4)) }
    return (mediaKind == .music ? "music:" : mediaKind == .audio ? "audio:" : "") + key
  }
  var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

enum Category: String, CaseIterable, Codable {
  case productivity, communication, social, entertainment, music, audio, learning, utilities,
    finance, shopping,
    news, other
}

struct UsageItem: Identifiable {
  let id: String
  let name: String
  let bundleID: String
  let domain: String?
  var duration: TimeInterval
  var visits: Int
  let category: Category
}

enum StoreError: LocalizedError {
  case database(String)
  case invalidInterval
  var errorDescription: String? {
    switch self {
    case .database(let message): return "Local database: \(message)"
    case .invalidInterval: return "Activity dates must be finite and the end must follow the start."
    }
  }
}

/// Local-only persistence. Every inserted interval is trimmed against existing
/// intervals globally: the first recorded activity owns overlapping time. Import
/// after live tracking therefore cannot inflate totals. All access is serialized.
final class ActivityStore {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open file"
      sqlite3_close(db)
      db = nil
      throw StoreError.database(message)
    }
    sqlite3_busy_timeout(db, 5_000)
    do {
      try execute(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS activity(id INTEGER PRIMARY KEY, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, domain TEXT, start REAL NOT NULL, end REAL NOT NULL CHECK(end>start), origin TEXT NOT NULL DEFAULT 'legacy'); CREATE INDEX IF NOT EXISTS activity_dates ON activity(start,end); CREATE TABLE IF NOT EXISTS categories(key TEXT PRIMARY KEY, category TEXT NOT NULL); CREATE TABLE IF NOT EXISTS imports(fingerprint TEXT PRIMARY KEY);"
      )
      try execute(
        "CREATE TABLE IF NOT EXISTS media(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, domain TEXT, start REAL NOT NULL, end REAL NOT NULL CHECK(end>start)); CREATE INDEX IF NOT EXISTS media_dates ON media(start,end);"
      )
      let legacy = try statement(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='video'")
      let hasLegacyVideo = sqlite3_step(legacy) == SQLITE_ROW
      sqlite3_finalize(legacy)
      if hasLegacyVideo {
        try transaction {
          try execute(
            "INSERT INTO media(kind,bundle_id,app_name,domain,start,end) SELECT 'video','daybook.video','Video playback',domain,start,end FROM video; DROP TABLE video;"
          )
        }
      }
      try migrateActivityOrigin()
      try normalizeExistingCategoryKeys()
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }

  deinit { sqlite3_close(db) }

  private func serialized<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }

  private func failure() -> StoreError { .database(String(cString: sqlite3_errmsg(db))) }

  private func statement(_ sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw failure()
    }
    return stmt
  }

  private func bind(_ value: String?, _ index: Int32, to stmt: OpaquePointer) {
    if let value {
      sqlite3_bind_text(stmt, index, value, -1, transient)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func string(_ stmt: OpaquePointer, _ index: Int32) -> String {
    sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func migrateActivityOrigin() throws {
    let query = try statement("PRAGMA table_info(activity)")
    var found = false
    var status = sqlite3_step(query)
    while status == SQLITE_ROW {
      if string(query, 1) == "origin" { found = true }
      status = sqlite3_step(query)
    }
    sqlite3_finalize(query)
    guard status == SQLITE_DONE else { throw failure() }
    if !found {
      try execute("ALTER TABLE activity ADD COLUMN origin TEXT NOT NULL DEFAULT 'legacy'")
    }
  }

  func append(bundleID: String, appName: String, domain: String?, start: Date, end: Date) throws {
    try serialized {
      try validate(start, end)
      try transaction {
        try insertUnoccupied(
          bundleID: bundleID, appName: appName, domain: domain, start: start, end: end,
          origin: "live")
      }
    }
  }

  private func validate(_ start: Date, _ end: Date) throws {
    guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start
    else { throw StoreError.invalidInterval }
  }

  private func insertUnoccupied(
    bundleID: String, appName: String, domain: String?, start: Date, end: Date, origin: String
  ) throws {
    var cursor = start
    let occupied = try sessions(from: start, to: end)
    for session in occupied {
      if session.start > cursor {
        try insert(bundleID, appName, domain, cursor, session.start, origin: origin)
      }
      cursor = max(cursor, session.end)
    }
    if cursor < end { try insert(bundleID, appName, domain, cursor, end, origin: origin) }
  }

  private func insert(
    _ bundleID: String, _ name: String, _ domain: String?, _ start: Date, _ end: Date,
    origin: String
  ) throws {
    // Checkpoints share exact boundaries. Coalesce only the same app/domain
    // and never bridge gaps or a different activity in between.
    let neighbors = try statement(
      "SELECT id,start,end FROM activity WHERE bundle_id=? AND domain IS ? AND (end=? OR start=?) AND origin=? ORDER BY start"
    )
    bind(bundleID, 1, to: neighbors)
    bind(domain, 2, to: neighbors)
    sqlite3_bind_double(neighbors, 3, start.timeIntervalSince1970)
    sqlite3_bind_double(neighbors, 4, end.timeIntervalSince1970)
    bind(origin, 5, to: neighbors)
    var mergedStart = start
    var mergedEnd = end
    var neighborIDs: [Int64] = []
    var neighborStatus = sqlite3_step(neighbors)
    while neighborStatus == SQLITE_ROW {
      neighborIDs.append(sqlite3_column_int64(neighbors, 0))
      mergedStart = min(
        mergedStart, Date(timeIntervalSince1970: sqlite3_column_double(neighbors, 1)))
      mergedEnd = max(mergedEnd, Date(timeIntervalSince1970: sqlite3_column_double(neighbors, 2)))
      neighborStatus = sqlite3_step(neighbors)
    }
    sqlite3_finalize(neighbors)
    guard neighborStatus == SQLITE_DONE else { throw failure() }
    if let retainedID = neighborIDs.first {
      let update = try statement("UPDATE activity SET start=?,end=?,app_name=? WHERE id=?")
      sqlite3_bind_double(update, 1, mergedStart.timeIntervalSince1970)
      sqlite3_bind_double(update, 2, mergedEnd.timeIntervalSince1970)
      bind(name, 3, to: update)
      sqlite3_bind_int64(update, 4, retainedID)
      let status = sqlite3_step(update)
      sqlite3_finalize(update)
      guard status == SQLITE_DONE else { throw failure() }
      for id in neighborIDs.dropFirst() {
        let deletion = try statement("DELETE FROM activity WHERE id=?")
        sqlite3_bind_int64(deletion, 1, id)
        let status = sqlite3_step(deletion)
        sqlite3_finalize(deletion)
        guard status == SQLITE_DONE else { throw failure() }
      }
      return
    }
    let stmt = try statement(
      "INSERT INTO activity(bundle_id,app_name,domain,start,end,origin) VALUES(?,?,?,?,?,?)")
    defer { sqlite3_finalize(stmt) }
    bind(bundleID, 1, to: stmt)
    bind(name, 2, to: stmt)
    bind(domain, 3, to: stmt)
    sqlite3_bind_double(stmt, 4, start.timeIntervalSince1970)
    sqlite3_bind_double(stmt, 5, end.timeIntervalSince1970)
    bind(origin, 6, to: stmt)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
  }

  /// Retroactively remove confirmed idle time from this app's live samples.
  /// Imported and legacy history is never changed by idle correction.
  func removeLiveActivity(from: Date, to: Date) throws {
    try serialized {
      try validate(from, to)
      try transaction {
        let query = try statement(
          "SELECT id,bundle_id,app_name,domain,start,end FROM activity WHERE origin='live' AND end>? AND start<? ORDER BY start,id"
        )
        sqlite3_bind_double(query, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(query, 2, to.timeIntervalSince1970)
        var affected: [ActivitySession] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
          affected.append(
            ActivitySession(
              id: sqlite3_column_int64(query, 0), bundleID: string(query, 1),
              appName: string(query, 2),
              domain: sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : string(query, 3),
              start: Date(timeIntervalSince1970: sqlite3_column_double(query, 4)),
              end: Date(timeIntervalSince1970: sqlite3_column_double(query, 5))))
          status = sqlite3_step(query)
        }
        sqlite3_finalize(query)
        guard status == SQLITE_DONE else { throw failure() }
        for session in affected {
          let deletion = try statement("DELETE FROM activity WHERE id=?")
          sqlite3_bind_int64(deletion, 1, session.id)
          let deleted = sqlite3_step(deletion)
          sqlite3_finalize(deletion)
          guard deleted == SQLITE_DONE else { throw failure() }
          if session.start < from {
            try insert(
              session.bundleID, session.appName, session.domain, session.start, from, origin: "live"
            )
          }
          if session.end > to {
            try insert(
              session.bundleID, session.appName, session.domain, to, session.end, origin: "live")
          }
        }
      }
    }
  }

  func sessions(from: Date, to: Date) throws -> [ActivitySession] {
    try serialized {
      guard to > from else { return [] }
      let stmt = try statement(
        "SELECT id,bundle_id,app_name,domain,start,end FROM activity WHERE end>? AND start<? ORDER BY start,id"
      )
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
      sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
      var result: [ActivitySession] = []
      var status = sqlite3_step(stmt)
      while status == SQLITE_ROW {
        result.append(
          ActivitySession(
            id: sqlite3_column_int64(stmt, 0), bundleID: string(stmt, 1), appName: string(stmt, 2),
            domain: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : string(stmt, 3),
            start: max(from, Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))),
            end: min(to, Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)))))
        status = sqlite3_step(stmt)
      }
      guard status == SQLITE_DONE else { throw failure() }
      return result
    }
  }

  func usage(from: Date, to: Date) throws -> [UsageItem] {
    try serialized {
      var items: [String: UsageItem] = [:]
      for session in try sessions(from: from, to: to) {
        let key = Self.normalizedKey(session.domain ?? session.bundleID)
        if var item = items[key] {
          item.duration += session.duration
          item.visits += 1
          items[key] = item
        } else {
          items[key] = UsageItem(
            id: key, name: session.domain == nil ? session.appName : key,
            bundleID: session.bundleID, domain: session.domain == nil ? nil : key,
            duration: session.duration, visits: 1, category: category(for: key))
        }
      }
      return items.values.sorted {
        $0.duration == $1.duration ? $0.id < $1.id : $0.duration > $1.duration
      }
    }
  }

  func appendVideo(domain: String, start: Date, end: Date) throws {
    try appendMedia(MediaSession(id: 0, domain: domain, start: start, end: end))
  }

  func appendMedia(_ session: MediaSession) throws {
    try serialized {
      try validate(session.start, session.end)
      let host: String?
      if let domain = session.domain {
        guard let canonical = PlaybackProtocol.canonicalDomain(domain) else {
          throw StoreError.database("Invalid media domain")
        }
        host = canonical.hasPrefix("www.") ? String(canonical.dropFirst(4)) : canonical
      } else {
        host = nil
      }
      guard !session.bundleID.isEmpty else { throw StoreError.database("Invalid media app") }
      try transaction {
        let query = try statement(
          "SELECT id,start,end FROM media WHERE kind=? AND bundle_id=? AND domain IS ? AND end>=? AND start<=? ORDER BY start"
        )
        bind(session.kind.rawValue, 1, to: query)
        bind(session.bundleID.lowercased(), 2, to: query)
        if let host { bind(host, 3, to: query) } else { sqlite3_bind_null(query, 3) }
        sqlite3_bind_double(query, 4, session.start.timeIntervalSince1970)
        sqlite3_bind_double(query, 5, session.end.timeIntervalSince1970)
        var a = session.start
        var b = session.end
        var ids: [Int64] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
          ids.append(sqlite3_column_int64(query, 0))
          a = min(a, Date(timeIntervalSince1970: sqlite3_column_double(query, 1)))
          b = max(b, Date(timeIntervalSince1970: sqlite3_column_double(query, 2)))
          status = sqlite3_step(query)
        }
        sqlite3_finalize(query)
        guard status == SQLITE_DONE else { throw failure() }
        for id in ids { try execute("DELETE FROM media WHERE id=\(id)") }
        let insert = try statement(
          "INSERT INTO media(kind,bundle_id,app_name,domain,start,end) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        bind(session.kind.rawValue, 1, to: insert)
        bind(session.bundleID.lowercased(), 2, to: insert)
        bind(session.appName, 3, to: insert)
        if let host { bind(host, 4, to: insert) } else { sqlite3_bind_null(insert, 4) }
        sqlite3_bind_double(insert, 5, a.timeIntervalSince1970)
        sqlite3_bind_double(insert, 6, b.timeIntervalSince1970)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
      }
    }
  }

  func mediaSessions(from: Date, to: Date) throws -> [MediaSession] {
    try serialized {
      guard to > from else { return [] }
      let query = try statement(
        "SELECT id,kind,bundle_id,app_name,domain,start,end FROM media WHERE end>? AND start<? ORDER BY start,id"
      )
      defer { sqlite3_finalize(query) }
      sqlite3_bind_double(query, 1, from.timeIntervalSince1970)
      sqlite3_bind_double(query, 2, to.timeIntervalSince1970)
      var rows: [MediaSession] = []
      var status = sqlite3_step(query)
      while status == SQLITE_ROW {
        guard let kind = MediaKind(rawValue: string(query, 1)) else {
          throw StoreError.database("Unknown media type")
        }
        rows.append(
          MediaSession(
            id: sqlite3_column_int64(query, 0),
            domain: sqlite3_column_type(query, 4) == SQLITE_NULL ? nil : string(query, 4),
            start: max(from, Date(timeIntervalSince1970: sqlite3_column_double(query, 5))),
            end: min(to, Date(timeIntervalSince1970: sqlite3_column_double(query, 6))), kind: kind,
            bundleID: string(query, 2), appName: string(query, 3)))
        status = sqlite3_step(query)
      }
      guard status == SQLITE_DONE else { throw failure() }
      return rows
    }
  }

  func videoSessions(from: Date, to: Date) throws -> [MediaSession] {
    try mediaSessions(from: from, to: to).filter { $0.kind == .video }
  }

  func category(for key: String) -> Category {
    serialized {
      guard let stmt = try? statement("SELECT category FROM categories WHERE key=?") else {
        return .other
      }
      defer { sqlite3_finalize(stmt) }
      bind(Self.normalizedKey(key), 1, to: stmt)
      if sqlite3_step(stmt) == SQLITE_ROW {
        let saved = string(stmt, 0)
        return saved == "work" ? .productivity : Category(rawValue: saved) ?? .other
      }
      return Self.automaticCategory(for: key)
    }
  }

  private static func normalizedKey(_ key: String) -> String {
    var value = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.contains("://"), let host = URLComponents(string: value)?.host { value = host }
    while value.hasSuffix(".") { value.removeLast() }
    if value.hasPrefix("www.") { value.removeFirst(4) }
    return value
  }

  func categoryOrigin(for key: String) -> String {
    serialized {
      if let query = try? statement("SELECT 1 FROM categories WHERE key=?") {
        defer { sqlite3_finalize(query) }
        bind(Self.normalizedKey(key), 1, to: query)
        if sqlite3_step(query) == SQLITE_ROW { return "Custom rule" }
      }
      return Self.automaticCategory(for: key) == .other
        ? "Other (no matching rule)" : "Built-in rule"
    }
  }

  private func normalizeExistingCategoryKeys() throws {
    let query = try statement("SELECT key,category FROM categories")
    var rows: [(String, String)] = []
    var status = sqlite3_step(query)
    while status == SQLITE_ROW {
      rows.append((string(query, 0), string(query, 1)))
      status = sqlite3_step(query)
    }
    sqlite3_finalize(query)
    guard status == SQLITE_DONE else { throw failure() }
    try transaction {
      for (key, category) in rows where key != Self.normalizedKey(key) {
        let insert = try statement("INSERT OR IGNORE INTO categories(key,category) VALUES(?,?)")
        bind(Self.normalizedKey(key), 1, to: insert)
        bind(category, 2, to: insert)
        let insertStatus = sqlite3_step(insert)
        sqlite3_finalize(insert)
        guard insertStatus == SQLITE_DONE else { throw failure() }
        let deletion = try statement("DELETE FROM categories WHERE key=?")
        bind(key, 1, to: deletion)
        let deletionStatus = sqlite3_step(deletion)
        sqlite3_finalize(deletion)
        guard deletionStatus == SQLITE_DONE else { throw failure() }
      }
    }
  }

  /// Offline defaults use known products, not broad word matching. Subdomains
  /// inherit only an explicit domain rule; lookalike names cannot match it.
  private static func automaticCategory(for key: String) -> Category {
    if key.hasPrefix("audio:") { return .audio }
    if key.hasPrefix("music:") || MusicSites.isDedicated(key.lowercased()) { return .music }
    if MusicSites.isMusicApp(key) { return .music }

    let value = normalizedKey(key)
    let installedApplications: [(Category, Set<String>)] = [
      (
        .productivity,
        [
          "com.cmuxterm.app", "io.beekeeperstudio.desktop", "xyz.chatboxapp.app",
          "com.conductor.app", "ai.opencode.desktop", "dev.kdrag0n.macvirt",
          "org.redislabs.redisinsight-v2", "org.pgadmin.pgadmin4", "org.audacityteam.audacity",
          "com.obsproject.obs-studio", "dj.studio.app", "com.mixedinkey.application",
        ]
      ),
      (
        .utilities,
        [
          "com.steipete.codexbar", "org.p0deje.maccy", "com.withopal.opalmacos",
          "com.remotemouse.remotemouseserver", "com.tunabellysoftware.tgpro",
          "com.apple.testflight", "com.wireguard.macos", "local.daybook.mac",
          "com.swiftui.timecard",
        ]
      ),
      (.learning, ["developer.apple.wwdc-release"]),
      (.entertainment, ["com.shazam.mac.shazam"]),
    ]
    for (category, bundles) in installedApplications where bundles.contains(value) {
      return category
    }
    let applications: [(Category, [String])] = [
      (
        .productivity,
        [
          "com.apple.dt.xcode", "com.microsoft.vscode", "com.microsoft.vscodeinsiders",
          "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.sublimetext.4",
          "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.webstorm",
          "com.googlecode.iterm2", "com.apple.terminal", "dev.warp.warp-stable",
          "com.mitchellh.ghostty", "com.microsoft.word", "com.microsoft.excel",
          "com.microsoft.powerpoint", "com.apple.iwork.pages", "com.apple.iwork.numbers",
          "com.apple.iwork.keynote", "com.figma.desktop", "notion.id", "md.obsidian",
          "com.apple.notes", "com.linear", "com.openai.chat", "com.openai.codex",
          "com.anthropic.claudefordesktop", "com.electron.replit", "com.adobe.photoshop",
          "com.adobe.illustrator", "com.bohemiancoding.sketch3", "com.culturedcode.thingsmac",
          "com.omnigroup.omnifocus4",
        ]
      ),
      (
        .communication,
        [
          "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams",
          "com.microsoft.outlook", "com.apple.mail", "com.apple.mobilemail", "us.zoom.xos",
          "com.hnc.discord", "ru.keepcoder.telegram", "ph.telegra.telegram",
          "desktop.keeweb.whatsapp", "net.whatsapp.whatsapp", "com.whatsapp.whatsapp",
          "com.apple.ichat", "com.apple.mobilesms", "org.whispersystems.signal-desktop",
          "com.readdle.smartemail-macos",
          "com.apple.facetime",
        ]
      ),
      (
        .social,
        [
          "com.atebits.tweetie2", "com.tapbots.ivory", "com.burbn.instagram",
          "com.facebook.facebook", "com.reddit.reddit",
        ]
      ),
      (
        .entertainment,
        [
          "com.spotify.client", "com.apple.music", "com.apple.tv", "com.apple.podcasts",
          "org.videolan.vlc", "com.colliderli.iina", "com.valvesoftware.steam",
          "com.epicgames.epicgameslauncher", "tv.twitch.desktopapp",
        ]
      ),
      (.learning, ["com.apple.ibooksx", "com.amazon.kindle", "org.ankiweb.dtop"]),
      (
        .utilities,
        [
          "com.apple.finder", "com.apple.systempreferences", "com.apple.systemsettings",
          "com.apple.activitymonitor", "com.apple.diskutility", "com.apple.archiveutility",
          "com.apple.preview", "com.apple.keychainaccess", "com.apple.passwords",
          "com.1password.1password", "com.1password.1password7", "com.bitwarden.desktop",
          "com.runningwithcrayons.alfred", "com.raycast.macos", "com.google.drivefs",
          "com.getdropbox.dropbox", "com.binarynights.forklift", "com.panic.transmit",
          "com.kapeli.dashdoc",
        ]
      ),
    ]
    for (category, bundles) in applications where bundles.contains(value) { return category }
    // JetBrains assigns a suffix per product edition; this is a documented
    // application namespace, distinct from arbitrary substring matching.
    if value.hasPrefix("com.jetbrains.") { return .productivity }
    let domains: [(Category, [String])] = [
      (
        .learning,
        [
          "developer.apple.com", "developer.mozilla.org", "docs.python.org", "docs.swift.org",
          "docs.rs", "doc.rust-lang.org", "learn.microsoft.com", "docs.anthropic.com",
          "platform.openai.com", "developers.openai.com", "coursera.org", "edx.org", "udemy.com",
          "khanacademy.org", "freecodecamp.org", "brilliant.org", "deeplearning.ai",
          "wikipedia.org",
        ]
      ),
      (
        .communication,
        [
          "mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
          "slack.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com",
          "discord.com", "web.whatsapp.com", "web.telegram.org", "proton.me",
        ]
      ),
      (
        .social,
        [
          "x.com", "twitter.com", "reddit.com", "instagram.com", "facebook.com", "threads.net",
          "threads.com", "bsky.app", "mastodon.social", "linkedin.com", "pinterest.com",
          "tiktok.com",
        ]
      ),
      (
        .entertainment,
        [
          "youtube.com", "youtu.be", "netflix.com", "spotify.com", "twitch.tv",
          "primevideo.com", "disneyplus.com", "hotstar.com", "jiocinema.com", "jiohotstar.com",
          "music.apple.com", "tv.apple.com", "soundcloud.com", "steampowered.com",
          "store.epicgames.com",
        ]
      ),
      (
        .productivity,
        [
          "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "stackexchange.com",
          "figma.com", "notion.so", "notion.site", "linear.app", "asana.com", "trello.com",
          "clickup.com", "airtable.com", "docs.google.com", "sheets.google.com",
          "slides.google.com", "drive.google.com", "calendar.google.com", "canva.com", "miro.com",
          "excalidraw.com", "chatgpt.com", "claude.ai", "replit.com", "v0.dev", "vercel.com",
          "netlify.com", "supabase.com", "console.cloud.google.com", "console.aws.amazon.com",
        ]
      ),
      (
        .utilities,
        [
          "1password.com", "bitwarden.com", "dropbox.com", "icloud.com", "fast.com",
          "speedtest.net",
        ]
      ),
      (
        .finance,
        [
          "hdfcbank.com", "hdfcbank.net", "icicibank.com", "axisbank.com", "axisbank.co.in",
          "onlinesbi.sbi", "sbi.co.in", "kotak.com", "indusind.com", "idfcfirstbank.com",
          "yesbank.in", "bankofbaroda.in", "americanexpress.com", "chase.com", "bankofamerica.com",
          "wellsfargo.com", "citi.com", "citibank.com", "hsbc.com", "hsbc.co.in", "barclays.co.uk",
          "natwest.com", "monzo.com", "revolut.com", "wise.com", "paypal.com", "paytm.com",
          "phonepe.com", "cred.club", "zerodha.com", "groww.in", "upstox.com", "angelone.in",
          "fidelity.com", "schwab.com", "vanguard.com", "robinhood.com", "coinbase.com",
          "incometax.gov.in", "cleartax.in",
        ]
      ),
      (
        .shopping,
        [
          "amazon.com", "amazon.in", "amazon.co.uk", "amazon.de", "amazon.ca", "amazon.co.jp",
          "flipkart.com", "myntra.com", "ajio.com", "nykaa.com", "meesho.com", "ebay.com",
          "etsy.com", "walmart.com", "target.com", "bestbuy.com", "aliexpress.com", "temu.com",
          "shein.com", "ikea.com", "uniqlo.com", "hm.com", "zara.com", "nike.com", "adidas.com",
          "bigbasket.com", "blinkit.com", "zepto.com", "swiggy.com", "zomato.com", "instamart.com",
        ]
      ),
      (
        .news,
        [
          "bbc.com", "bbc.co.uk", "reuters.com", "apnews.com", "theguardian.com", "nytimes.com",
          "washingtonpost.com", "wsj.com", "ft.com", "bloomberg.com", "cnn.com", "npr.org",
          "aljazeera.com", "economist.com", "thehindu.com", "indianexpress.com",
          "hindustantimes.com", "timesofindia.indiatimes.com", "ndtv.com", "livemint.com",
          "business-standard.com", "economictimes.indiatimes.com", "moneycontrol.com",
          "news.ycombinator.com", "techcrunch.com", "theverge.com", "arstechnica.com", "wired.com",
        ]
      ),
    ]
    for (category, roots) in domains {
      if roots.contains(where: { value == $0 || value.hasSuffix("." + $0) }) { return category }
    }
    return .other
  }

  func setCategory(_ category: Category, for key: String) throws {
    try serialized {
      let stmt = try statement(
        "INSERT INTO categories(key,category) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET category=excluded.category"
      )
      defer { sqlite3_finalize(stmt) }
      bind(Self.normalizedKey(key), 1, to: stmt)
      bind(category.rawValue, 2, to: stmt)
      guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
  }

  /// Timecard 2.2.1 stores Unix seconds; confirmed against source dates. Source
  /// is opened read-only. A content fingerprint survives copies and reimports.
  /// Only explicit Mac device rows are accepted; phone/unknown rows are skipped.
  func importTimecard(from url: URL) throws -> Int {
    try serialized {
      var source: OpaquePointer?
      guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not read import"
        sqlite3_close(source)
        throw StoreError.database(message)
      }
      defer { sqlite3_close(source) }
      var query: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          source,
          "SELECT id,bundle_id,domain,start,end,source,device FROM session ORDER BY start,id", -1,
          &query, nil) == SQLITE_OK, let query
      else {
        throw StoreError.database("This file does not have Timecard’s session table.")
      }
      defer { sqlite3_finalize(query) }
      return try transaction {
        var count = 0
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
          let device = string(query, 6).lowercased()
          if device.contains("mac") {
            let bundle = string(query, 1)
            let domain = sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : string(query, 2)
            let start = Date(timeIntervalSince1970: sqlite3_column_double(query, 3))
            let end = Date(timeIntervalSince1970: sqlite3_column_double(query, 4))
            if start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start
            {
              let fields = [
                string(query, 0), bundle, domain ?? "", string(query, 3), string(query, 4),
                string(query, 5), device,
              ]
              let fingerprint = String(data: try JSONEncoder().encode(fields), encoding: .utf8)!
              let marker = try statement("INSERT OR IGNORE INTO imports(fingerprint) VALUES(?)")
              bind(fingerprint, 1, to: marker)
              let markerStatus = sqlite3_step(marker)
              let isNew = sqlite3_changes(db) > 0
              sqlite3_finalize(marker)
              guard markerStatus == SQLITE_DONE else { throw failure() }
              if isNew {
                let name = bundle.split(separator: ".").last.map(String.init) ?? bundle
                try insertUnoccupied(
                  bundleID: bundle, appName: name, domain: domain, start: start, end: end,
                  origin: "imported")
                count += 1
              }
            }
          }
          status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else {
          throw StoreError.database("Could not finish reading Timecard sessions.")
        }
        return count
      }
    }
  }

  func exportCSV(from: Date, to: Date) throws -> String {
    func quoted(_ value: String) -> String {
      // Prevent spreadsheet formula execution while retaining plain CSV.
      let safe =
        ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
      return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    let formatter = ISO8601DateFormatter()
    var lines = ["app,bundle_id,domain,start,end,duration_seconds,kind"]
    for session in try sessions(from: from, to: to) {
      lines.append(
        [
          session.appName, session.bundleID, session.domain ?? "",
          formatter.string(from: session.start), formatter.string(from: session.end),
          String(session.duration), "foreground",
        ].map(quoted).joined(separator: ","))
    }
    for session in try mediaSessions(from: from, to: to) {
      lines.append(
        [
          session.appName, session.bundleID, session.domain ?? "",
          formatter.string(from: session.start),
          formatter.string(from: session.end), String(session.duration), session.kind.rawValue,
        ].map(quoted).joined(separator: ","))
    }
    return lines.joined(separator: "\r\n") + "\r\n"
  }
}
