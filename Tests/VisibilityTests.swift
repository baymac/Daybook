import CoreGraphics
import Foundation
import SQLite3

@main enum VisibilityTests {
  static func main() throws {
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let player = CGRect(x: -1600, y: 100, width: 1000, height: 600)
    let windows = [
      WindowGeometry(id: 1, pid: 10, bounds: display),
      WindowGeometry(id: 2, pid: 20, bounds: player),
    ]
    assert(
      VisibilityMath.isVisible(
        player, windowIndex: 1, windows: windows, displays: [display, second]),
      "Unfocused video on the other display must count")
    assert(
      !VisibilityMath.isVisible(player, windowIndex: 1, windows: windows, displays: [display]),
      "A disconnected display must not count")
    let covered = [WindowGeometry(id: 3, pid: 30, bounds: player)] + windows
    assert(
      !VisibilityMath.isVisible(
        player, windowIndex: 2, windows: covered, displays: [display, second]),
      "A fully covered player must stop")
    let partial = [
      WindowGeometry(id: 3, pid: 30, bounds: CGRect(x: -1600, y: 100, width: 800, height: 600)),
      windows[1],
    ]
    assert(VisibilityMath.isVisible(player, windowIndex: 1, windows: partial, displays: [second]))
    let sliver = [
      WindowGeometry(id: 3, pid: 30, bounds: CGRect(x: -1600, y: 100, width: 999, height: 600)),
      windows[1],
    ]
    assert(
      !VisibilityMath.isVisible(player, windowIndex: 1, windows: sliver, displays: [second]),
      "A tiny exposed border is not watching")
    assert(
      VisibilityMath.matchingWindow(pid: 20, bounds: player, windows: [windows[0]]) == nil,
      "Minimized/other Space window absent from onscreen list must stop")
    assert(
      VisibilityMath.matchingWindow(pid: 10, bounds: player, windows: windows) == nil,
      "Do not confuse browser windows with another process")
    let glass = [WindowGeometry(id: 3, pid: 30, bounds: player, alpha: 0.5), windows[1]]
    assert(VisibilityMath.isVisible(player, windowIndex: 1, windows: glass, displays: [second]))
    for site in MusicSites.dedicated {
      assert(MusicSites.kind(domain: site, playing: true, visible: false, audible: true) == .music)
      assert(MusicSites.kind(domain: site, playing: true, visible: true, audible: false) == nil)
    }
    assert(
      MusicSites.kind(domain: "youtube.com", playing: true, visible: true, audible: false) == .video
    )
    assert(
      MusicSites.kind(domain: "youtube.com", playing: true, visible: false, audible: true) == .music
    )
    assert(
      MusicSites.kind(domain: "youtube.com", playing: true, visible: false, audible: false) == nil)
    assert(
      MusicSites.kind(domain: "sports.example.com", playing: true, visible: false, audible: true)
        == nil)
    assert(
      MusicSites.kind(domain: "notyoutube.com", playing: true, visible: false, audible: true) == nil
    )
    assert(
      MusicSites.kind(domain: "youtube.com.evil.test", playing: true, visible: false, audible: true)
        == nil)
    assert(
      MusicSites.kind(domain: "sports.example.com", playing: true, visible: true, audible: true)
        == .video)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var ledger = PlaybackLedger()
    func feed(_ t: Double, _ kind: MediaKind?, _ playing: Bool = true) -> MediaSession? {
      let date = now.addingTimeInterval(t)
      return ledger.consume(
        session: "test", bundleID: "browser", appName: "Browser", domain: "youtube.com", kind: kind,
        playing: playing, date: date, now: date)
    }
    assert(feed(0, .video) == nil)
    assert(feed(2, .video)?.kind == .video)
    assert(feed(4, .music) == nil, "Never bridge a watching/listening transition")
    assert(feed(6, .music)?.kind == .music)
    ledger.discardUnless("test", kind: nil)
    assert(feed(8, .music) == nil, "Visibility guard must break covered/muted gaps")
    assert(feed(10, nil) == nil)
    assert(feed(12, .video) == nil)

    var progress = NativeProgress()
    func sample(_ time: Double, _ playing: Bool = true) -> NativeMediaSample {
      NativeMediaSample(
        source: "native:10:1", bundleID: "org.videolan.vlc", appName: "VLC", pid: 10,
        playing: playing, position: time, audio: false, video: true, bounds: nil)
    }
    assert(!progress.playing(sample(0), now: now))
    assert(progress.playing(sample(1), now: now.addingTimeInterval(1)))
    assert(progress.playing(sample(1), now: now.addingTimeInterval(2)))
    assert(!progress.playing(sample(1), now: now.addingTimeInterval(4)))
    assert(!progress.playing(sample(2, false), now: now.addingTimeInterval(5)))

    var audio = AudioPresence()
    assert(audio.consume(source: "app", audible: true, now: now) == nil)
    assert(audio.consume(source: "app", audible: true, now: now.addingTimeInterval(1)) == nil)
    assert(
      audio.consume(source: "app", audible: false, now: now.addingTimeInterval(2)) == nil,
      "Short notification sounds must not count as listening")
    assert(audio.consume(source: "app", audible: true, now: now.addingTimeInterval(10)) == nil)
    assert(audio.consume(source: "app", audible: true, now: now.addingTimeInterval(11)) == nil)
    assert(audio.consume(source: "app", audible: true, now: now.addingTimeInterval(12)) == nil)
    assert(
      audio.consume(source: "app", audible: true, now: now.addingTimeInterval(13))?.duration == 3,
      "Sustained audio includes its confirmed start")
    assert(
      audio.consume(source: "app", audible: true, now: now.addingTimeInterval(14))?.duration == 1)
    assert(
      audio.consume(source: "app", audible: true, now: now.addingTimeInterval(20)) == nil,
      "Do not fill missing audio observations")
    audio.clear()
    assert(audio.consume(source: "app", audible: true, now: now.addingTimeInterval(21)) == nil)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("legacy.sqlite")
    var db: OpaquePointer?
    assert(sqlite3_open(url.path, &db) == SQLITE_OK)
    assert(
      sqlite3_exec(
        db,
        "CREATE TABLE video(id INTEGER PRIMARY KEY,domain TEXT NOT NULL,start REAL NOT NULL,end REAL NOT NULL); INSERT INTO video VALUES(1,'youtube.com',1800000000,1800003600);",
        nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    do {
      let store = try ActivityStore(url: url)
      let legacy = try store.mediaSessions(from: now, to: now.addingTimeInterval(7200))
      assert(legacy.count == 1 && legacy[0].kind == .video && legacy[0].duration == 3600)
      try store.appendMedia(
        MediaSession(
          id: 0, domain: "youtube.com", start: now, end: now.addingTimeInterval(120), kind: .music))
      try store.appendMedia(
        MediaSession(
          id: 0, domain: nil, start: now, end: now.addingTimeInterval(120), kind: .music,
          bundleID: "com.spotify.client", appName: "Spotify"))
      assert(store.category(for: "music:youtube.com") == .music)
      assert(store.category(for: "youtube.com") == .entertainment)
      let csv = try store.exportCSV(from: now, to: now.addingTimeInterval(7200))
      assert(csv.contains("Spotify") && csv.contains("\"music\""))
    }
    let reopened = try ActivityStore(url: url)
    let rows = try reopened.mediaSessions(from: now, to: now.addingTimeInterval(7200))
    assert(rows.count == 3, "Migration is idempotent and keeps native/browser music separate")
    assert(PlaybackMath.duration(rows.map { DateInterval(start: $0.start, end: $0.end) }) == 3600)
    print(
      "Visibility/media tests passed: two displays, cover, slivers, minimization, music policy, transitions, native progress, migration, CSV and overlap totals."
    )
  }
}
