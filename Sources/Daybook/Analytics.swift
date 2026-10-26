import Foundation

enum ActivityAnalytics {
  private static let continuityTolerance: TimeInterval = 5
  private static let focusMinimum: TimeInterval = 25 * 60

  static func switchCount(_ sessions: [ActivitySession]) -> Int {
    switchesByApp(sessions).values.reduce(0, +)
  }

  /// Switches are attributed to the app entered. Website changes within one
  /// browser are not foreground app changes, and idle gaps start a fresh run.
  static func switchesByApp(_ sessions: [ActivitySession]) -> [String: Int] {
    var counts: [String: Int] = [:]
    var previous: ActivitySession?
    for session in normalized(sessions) {
      if let previous,
        session.start.timeIntervalSince(previous.end) <= continuityTolerance,
        session.bundleID != previous.bundleID
      {
        counts[session.bundleID, default: 0] += 1
      }
      previous = session
    }
    return counts
  }

  /// Productive apps may change during a focus stretch. Only recorded active
  /// seconds count toward the 25 minute threshold; small gaps add no time.
  static func focusTime(_ sessions: [ActivitySession], category: (ActivitySession) -> Category)
    -> TimeInterval
  {
    var total: TimeInterval = 0
    var stretch: TimeInterval = 0
    var previousEnd: Date?
    for session in normalized(sessions) {
      let kind = category(session)
      let productive = kind == .productivity || kind == .learning
      if !productive
        || previousEnd.map({ session.start.timeIntervalSince($0) > continuityTolerance }) == true
      {
        if stretch >= focusMinimum { total += stretch }
        stretch = 0
      }
      if productive { stretch += session.duration }
      previousEnd = session.end
    }
    if stretch >= focusMinimum { total += stretch }
    return total
  }

  /// The store normally supplies disjoint intervals. For malformed imported
  /// arrays, earlier intervals own overlaps, matching store insertion policy.
  private static func normalized(_ sessions: [ActivitySession]) -> [ActivitySession] {
    let ordered = sessions.filter {
      $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
        && $0.end.timeIntervalSince($0.start).isFinite && $0.end > $0.start
    }.sorted {
      if $0.start != $1.start { return $0.start < $1.start }
      if $0.id != $1.id { return $0.id < $1.id }
      if $0.end != $1.end { return $0.end < $1.end }
      return $0.bundleID < $1.bundleID
    }
    var result: [ActivitySession] = []
    var occupiedUntil: Date?
    for session in ordered {
      let start = occupiedUntil.map { max($0, session.start) } ?? session.start
      guard session.end > start else { continue }
      result.append(
        ActivitySession(
          id: session.id, bundleID: session.bundleID, appName: session.appName,
          domain: session.domain, start: start, end: session.end))
      occupiedUntil = session.end
    }
    return result
  }
}

enum TrackingPolicy {
  /// Never bridge a suspended laptop or a missed sampling window. The tracker
  /// separately removes the entire preceding idle span when it detects idle.
  static func interval(
    start: Date, end: Date, idleSeconds: TimeInterval, idleLimit: TimeInterval, wasIdle: Bool
  ) -> DateInterval? {
    let elapsed = end.timeIntervalSince(start)
    guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
      elapsed.isFinite, elapsed > 0, elapsed <= 15,
      idleSeconds.isFinite, idleSeconds >= 0,
      idleLimit.isFinite, idleLimit > 0, idleSeconds < idleLimit
    else { return nil }
    let activeStart = wasIdle ? max(start, end.addingTimeInterval(-idleSeconds)) : start
    guard activeStart < end else { return nil }
    return DateInterval(start: activeStart, end: end)
  }
}
