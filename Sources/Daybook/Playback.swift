import CryptoKit
import Foundation

struct VideoSession: Identifiable {
  let id: Int64
  let domain: String
  let start: Date
  let end: Date
  var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct PlaybackPacket: Codable {
  let version: Int
  let session: String
  let domain: String
  let playing: Bool
  let sentAt: Double
}

struct SignedPlaybackPacket: Codable {
  let payload: String
  let mac: String
}

enum PlaybackProtocol {
  static let notification = Notification.Name("local.daybook.videoHeartbeat.v1")
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
      let wrapper = try? JSONDecoder().decode(SignedPlaybackPacket.self, from: data),
      wrapper.payload.count <= 4096, let payload = Data(base64Encoded: wrapper.payload),
      let key = keyData(code), let mac = keyData(wrapper.mac),
      HMAC<SHA256>.isValidAuthenticationCode(
        mac, authenticating: payload, using: SymmetricKey(data: key)),
      let packet = try? JSONDecoder().decode(PlaybackPacket.self, from: payload),
      packet.version == 1, packet.session.count <= 128, !packet.session.isEmpty,
      packet.session.range(of: "^[a-zA-Z0-9_.:-]+$", options: .regularExpression) != nil,
      packet.sentAt.isFinite, now.timeIntervalSince1970 - packet.sentAt >= -5,
      now.timeIntervalSince1970 - packet.sentAt <= 15,
      canonicalDomain(packet.domain) == packet.domain
    else { return nil }
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

/// Heartbeats prove an interval; a missing heartbeat never grants an open lease.
struct PlaybackLedger {
  private var states: [String: (domain: String, date: Date)] = [:]
  mutating func clear() { states.removeAll() }
  mutating func discard(_ session: String) { states.removeValue(forKey: session) }
  mutating func consume(_ packet: PlaybackPacket, now: Date) -> VideoSession? {
    let date = min(now, Date(timeIntervalSince1970: packet.sentAt))
    states = states.filter { now.timeIntervalSince($0.value.date) <= 15 }
    let old = states[packet.session]
    if let old, date <= old.date { return nil }
    if packet.playing {
      guard states.count < 128 || old != nil else { return nil }
      states[packet.session] = (packet.domain, date)
    } else {
      states.removeValue(forKey: packet.session)
    }
    guard let old, old.domain == packet.domain,
      date > old.date, date.timeIntervalSince(old.date) <= 12
    else { return nil }
    return VideoSession(id: 0, domain: packet.domain, start: old.date, end: date)
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
