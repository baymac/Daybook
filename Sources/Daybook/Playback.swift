import CryptoKit
import Foundation

enum MediaKind: String, Codable { case video, music, audio }

struct MediaSession: Identifiable {
  let id: Int64
  let kind: MediaKind
  let bundleID: String
  let appName: String
  let domain: String?
  let start: Date
  let end: Date
  var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
  var key: String {
    (kind == .music ? "music:" : kind == .audio ? "audio:" : "") + (domain ?? bundleID.lowercased())
  }
  init(
    id: Int64, domain: String?, start: Date, end: Date, kind: MediaKind = .video,
    bundleID: String = "daybook.video", appName: String = "Video playback"
  ) {
    self.id = id
    self.domain = domain
    self.start = start
    self.end = end
    self.kind = kind
    self.bundleID = bundleID
    self.appName = appName
  }
}

struct PlaybackPacket: Codable {
  let version: Int
  let session: String
  let domain: String
  let playing: Bool
  let sentAt: Double
  var context: BrowserPlaybackContext? = nil
  var messageID: String? = nil
}

struct EncryptedPlaybackPacket: Codable {
  let version: Int
  let nonce: String
  let ciphertext: String
}

enum PlaybackProtocol {
  static let notification = Notification.Name("local.daybook.mediaHeartbeat.v2")
  static let authenticatedData = Data("local.daybook.playback.v2".utf8)
  static func newPairingCode() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes {
      Data($0).map { String(format: "%02x", $0) }.joined()
    }
  }

  static func keyData(_ code: String) -> Data? {
    guard code.count == 64 else { return nil }
    var result = Data()
    var cursor = code.startIndex
    for _ in 0..<32 {
      let next = code.index(cursor, offsetBy: 2)
      guard let byte = UInt8(code[cursor..<next], radix: 16) else { return nil }
      result.append(byte)
      cursor = next
    }
    return result
  }

  static func decode(_ object: String, code: String, now: Date) -> PlaybackPacket? {
    guard object.utf8.count <= 8192, let data = object.data(using: .utf8),
      let wrapper = try? JSONDecoder().decode(EncryptedPlaybackPacket.self, from: data),
      wrapper.version == 2,
      wrapper.nonce.count == 16, let nonce = Data(base64Encoded: wrapper.nonce), nonce.count == 12,
      wrapper.ciphertext.count <= 5500, let sealed = Data(base64Encoded: wrapper.ciphertext),
      sealed.count >= 16,
      let key = keyData(code),
      let box = try? AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)),
      let payload = try? AES.GCM.open(
        box, using: SymmetricKey(data: key), authenticating: authenticatedData),
      var packet = try? JSONDecoder().decode(PlaybackPacket.self, from: payload),
      packet.version == 1 || packet.version == 2,
      packet.version != 2 || packet.context?.valid == true, packet.session.count <= 128,
      !packet.session.isEmpty,
      packet.session.range(of: "^[a-zA-Z0-9_.:-]+$", options: .regularExpression) != nil,
      packet.sentAt.isFinite, now.timeIntervalSince1970 - packet.sentAt >= -5,
      now.timeIntervalSince1970 - packet.sentAt <= 15,
      canonicalDomain(packet.domain) == packet.domain
    else { return nil }
    packet.messageID = wrapper.nonce
    return packet
  }

  static func canonicalDomain(_ value: String) -> String? {
    let host = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard host.utf8.count <= 253, host.contains("."),
      host.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
      !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
      let url = URL(string: "https://" + host), url.host == host
    else { return nil }
    return host
  }
}

/// Retain message identities across pause/resume so captured ciphertext cannot be replayed.
struct PlaybackReplayWindow {
  private var seen: [String: Date] = [:]
  mutating func accept(_ id: String, now: Date) -> Bool {
    seen = seen.filter { now.timeIntervalSince($0.value) <= 20 }
    guard seen[id] == nil, seen.count < 4096 else { return false }
    seen[id] = now
    return true
  }
}

/// Two recent, matching signals prove an interval. A mode change never fills a visibility gap.
struct PlaybackLedger {
  private struct State {
    let kind: MediaKind
    let bundleID: String
    let appName: String
    let domain: String?
    let date: Date
  }
  private var states: [String: State] = [:]
  mutating func clear() { states.removeAll() }
  mutating func discard(_ session: String) { states.removeValue(forKey: session) }
  mutating func discardUnless(_ session: String, kind: MediaKind?) {
    if states[session]?.kind != kind { states.removeValue(forKey: session) }
  }
  mutating func consume(_ packet: PlaybackPacket, now: Date, kind: MediaKind? = .video)
    -> MediaSession?
  {
    consume(
      session: packet.session, bundleID: "daybook.video", appName: "Video playback",
      domain: packet.domain, kind: kind, playing: packet.playing,
      date: Date(timeIntervalSince1970: packet.sentAt), now: now)
  }
  mutating func consume(
    session: String, bundleID: String, appName: String, domain: String?, kind: MediaKind?,
    playing: Bool, date inputDate: Date, now: Date
  ) -> MediaSession? {
    let date = min(now, inputDate)
    states = states.filter { now.timeIntervalSince($0.value.date) <= 15 }
    let old = states[session]
    if let old, date <= old.date { return nil }
    if playing, let kind {
      guard states.count < 128 || old != nil else { return nil }
      states[session] = State(
        kind: kind, bundleID: bundleID, appName: appName, domain: domain, date: date)
    } else {
      states.removeValue(forKey: session)
    }
    guard let old, old.domain == domain, old.bundleID == bundleID,
      !playing || old.kind == kind, date > old.date, date.timeIntervalSince(old.date) <= 12
    else { return nil }
    return MediaSession(
      id: 0, domain: domain, start: old.date, end: date, kind: old.kind, bundleID: bundleID,
      appName: appName)
  }
}

enum PlaybackMath {
  static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
    let sorted = intervals.filter {
      $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
        && $0.duration > 0
    }
    .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    var result: [DateInterval] = []
    for interval in sorted {
      if let last = result.last, interval.start <= last.end {
        result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
      } else {
        result.append(interval)
      }
    }
    return result
  }
  static func duration(_ intervals: [DateInterval]) -> TimeInterval {
    merged(intervals).reduce(0) { $0 + $1.duration }
  }
}
