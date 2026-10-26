import CoreGraphics
import Foundation

struct NativeMediaSample {
  let source: String
  let bundleID: String
  let appName: String
  let pid: Int32
  let playing: Bool
  let position: Double
  let audio: Bool
  let video: Bool
  let bounds: CGRect?
}

/// A player's "playing" flag alone can also mean buffering. Require progress.
struct NativeProgress {
  private struct State {
    let position: Double
    let advanced: Date
    let seen: Date
  }
  private var states: [String: State] = [:]
  mutating func clear() { states.removeAll() }
  mutating func playing(_ sample: NativeMediaSample, now: Date) -> Bool {
    states = states.filter { now.timeIntervalSince($0.value.seen) < 15 }
    guard sample.playing, sample.position.isFinite, sample.position >= 0 else {
      states.removeValue(forKey: sample.source)
      return false
    }
    let previous = states[sample.source]
    let moved =
      previous.map { sample.position > $0.position + 0.02 && sample.position - $0.position < 8 }
      ?? false
    let advanced = moved ? now : previous?.advanced ?? .distantPast
    states[sample.source] = State(position: sample.position, advanced: advanced, seen: now)
    // VLC reports whole seconds; tolerate repeated integer samples briefly.
    return now.timeIntervalSince(advanced) <= 2.5
  }
}
