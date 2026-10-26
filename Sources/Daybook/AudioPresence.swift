import Foundation

/// Ignore short alerts. Once sustained playback is confirmed, include its start.
struct AudioPresence {
  private struct State {
    let start: Date
    let last: Date
    let confirmed: Bool
  }
  private var states: [String: State] = [:]
  mutating func clear() { states.removeAll() }
  mutating func consume(source: String, audible: Bool, now: Date) -> DateInterval? {
    states = states.filter { now.timeIntervalSince($0.value.last) <= 3 }
    guard audible else {
      states.removeValue(forKey: source)
      return nil
    }
    let old = states[source].flatMap {
      now.timeIntervalSince($0.last) <= 2.5 && now > $0.last ? $0 : nil
    }
    let start = old?.start ?? now
    let confirmed = now.timeIntervalSince(start) >= 3
    states[source] = State(start: start, last: now, confirmed: confirmed)
    guard let old, confirmed else { return nil }
    return DateInterval(start: old.confirmed ? old.last : start, end: now)
  }
}
