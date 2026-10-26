import CryptoKit
import Foundation

@main enum PlaybackTests {
  static func main() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let code = String(repeating: "ab", count: 32)
    func packet(
      _ second: Double, _ playing: Bool = true, _ domain: String = "youtube.com",
      _ session: String = "test:1"
    ) -> PlaybackPacket {
      PlaybackPacket(
        version: 1, session: session, domain: domain, playing: playing,
        sentAt: now.timeIntervalSince1970 + second)
    }
    func signed(_ p: PlaybackPacket) -> String {
      let data = try! JSONEncoder().encode(p)
      let box = try! AES.GCM.seal(
        data, using: SymmetricKey(data: PlaybackProtocol.keyData(code)!),
        authenticating: PlaybackProtocol.authenticatedData)
      return String(
        data: try! JSONEncoder().encode(
          EncryptedPlaybackPacket(
            version: 2,
            nonce: box.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: (box.ciphertext + box.tag).base64EncodedString())), encoding: .utf8)!

    }
    let encrypted = signed(packet(0))
    assert(!encrypted.contains("youtube.com") && !encrypted.contains("test:1"))
    assert(PlaybackProtocol.decode(encrypted, code: code, now: now) != nil)
    var tampered = try! JSONDecoder().decode(
      EncryptedPlaybackPacket.self, from: Data(encrypted.utf8))
    var bytes = Data(base64Encoded: tampered.ciphertext)!
    bytes[0] ^= 1
    tampered = EncryptedPlaybackPacket(
      version: 2, nonce: tampered.nonce, ciphertext: bytes.base64EncodedString())
    assert(
      PlaybackProtocol.decode(
        String(data: try! JSONEncoder().encode(tampered), encoding: .utf8)!, code: code, now: now)
        == nil)
    assert(
      PlaybackProtocol.decode(
        "{\"payload\":\"plaintext\",\"mac\":\"legacy\"}", code: code, now: now) == nil)
    assert(
      PlaybackProtocol.decode(signed(packet(0)), code: String(repeating: "cd", count: 32), now: now)
        == nil)
    assert(PlaybackProtocol.decode(signed(packet(-16)), code: code, now: now) == nil)
    assert(PlaybackProtocol.decode(signed(packet(6)), code: code, now: now) == nil)
    assert(
      PlaybackProtocol.decode(signed(packet(0, true, "example.com/path")), code: code, now: now)
        == nil)
    assert(
      PlaybackProtocol.decode(
        signed(packet(0, true, "youtube.com", "../../path")), code: code, now: now) == nil)

    var replay = PlaybackReplayWindow()
    assert(replay.accept("one", now: now))
    assert(!replay.accept("one", now: now.addingTimeInterval(10)))
    assert(replay.accept("two", now: now.addingTimeInterval(10)))
    assert(replay.accept("one", now: now.addingTimeInterval(21)))
    // Expired messages are independently rejected by the authenticated timestamp check.
    var ledger = PlaybackLedger()
    assert(ledger.consume(packet(0), now: now) == nil)
    var intervals: [DateInterval] = []
    for t in stride(from: 5.0, through: 7200.0, by: 5.0) {
      let p = packet(t)
      let value = ledger.consume(p, now: now.addingTimeInterval(t))!
      intervals.append(DateInterval(start: value.start, end: value.end))
      assert(
        ledger.consume(p, now: now.addingTimeInterval(t)) == nil,
        "Duplicate signals must not count twice")
    }
    assert(
      PlaybackMath.duration(intervals) == 7200,
      "Two hours of background playback must count as two hours")
    let foreground = [DateInterval(start: now, end: now.addingTimeInterval(720))]
    assert(
      PlaybackMath.duration(foreground + intervals) == 7200,
      "Foreground plus same-time video must not inflate computer time")
    assert(ledger.consume(packet(7201, false), now: now.addingTimeInterval(7201))?.duration == 1)
    assert(ledger.consume(packet(7210, false), now: now.addingTimeInterval(7210)) == nil)
    assert(ledger.consume(packet(7300), now: now.addingTimeInterval(7300)) == nil)
    assert(
      ledger.consume(packet(7320), now: now.addingTimeInterval(7320)) == nil,
      "Missing heartbeats must not be backfilled")
    ledger.clear()
    assert(
      ledger.consume(packet(7325), now: now.addingTimeInterval(7325)) == nil,
      "Sleep/pause must break the interval")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ActivityStore(url: folder.appendingPathComponent("test.sqlite"))
    try store.append(
      bundleID: "com.microsoft.VSCode", appName: "Code", domain: nil, start: now,
      end: now.addingTimeInterval(7200))
    try store.appendVideo(
      domain: "youtube.com", start: now, end: now.addingTimeInterval(3600))
    try store.appendVideo(
      domain: "youtube.com", start: now.addingTimeInterval(1800),
      end: now.addingTimeInterval(7200))
    try store.appendVideo(
      domain: "youtube.com", start: now, end: now.addingTimeInterval(7200))
    let video = try store.videoSessions(from: now, to: now.addingTimeInterval(7200))
    assert(
      video.count == 1 && video[0].duration == 7200,
      "Duplicate frames/tabs on one site must not multiply video time")
    let clipped = try store.videoSessions(
      from: now.addingTimeInterval(3600), to: now.addingTimeInterval(5400))
    assert(clipped[0].duration == 1800)
    try store.removeLiveActivity(from: now, to: now.addingTimeInterval(7200))
    let afterIdle = try store.sessions(from: now, to: now.addingTimeInterval(7200))
    assert(afterIdle.isEmpty)
    let preserved = try store.videoSessions(from: now, to: now.addingTimeInterval(7200))
    assert(preserved[0].duration == 7200, "Idle correction must preserve confirmed video playback")
    assert(store.category(for: "youtube.com") == .entertainment)
    print(
      "Playback tests passed: two-hour background stream, pause, missing signals, duplicates, authentication, overlap totals, clipping, persistence and idle preservation."
    )
  }
}
