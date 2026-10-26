import Foundation

@main
struct AnalyticsTests {
  static func main() {
    func session(_ id: Int64, _ app: String, _ start: Double, _ end: Double, domain: String? = nil)
      -> ActivitySession
    {
      ActivitySession(
        id: id, bundleID: app, appName: app, domain: domain,
        start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }
    func category(_ session: ActivitySession) -> Category {
      if session.bundleID == "learn" { return .learning }
      if session.bundleID == "work" || session.bundleID == "browser" { return .productivity }
      return .social
    }
    let transitions = [
      session(1, "work", 0, 30), session(2, "browser", 30, 60, domain: "a.test"),
      session(3, "browser", 60, 90, domain: "b.test"), session(4, "learn", 95, 100),
      session(5, "work", 106, 110),
    ]
    precondition(
      ActivityAnalytics.switchCount(transitions.reversed()) == 2,
      "Sorted app switches include five second continuity but not six second idle gaps or domain changes"
    )
    precondition(ActivityAnalytics.switchesByApp(transitions) == ["browser": 1, "learn": 1])
    precondition(
      ActivityAnalytics.switchCount([
        session(1, "work", 0, 10), session(2, "social", 10, 10), session(3, "work", 10, 20),
      ]) == 0)
    precondition(
      ActivityAnalytics.focusTime([session(1, "work", 0, 1500)], category: category) == 1500)
    precondition(
      ActivityAnalytics.focusTime([session(1, "work", 0, 1499)], category: category) == 0)
    let focus = [session(1, "work", 0, 900), session(2, "learn", 905, 1505)]
    precondition(
      ActivityAnalytics.focusTime(focus.reversed(), category: category) == 1500,
      "Productive switches preserve focus and five second gaps do not inflate it")
    precondition(
      ActivityAnalytics.focusTime(
        [session(1, "work", 0, 900), session(2, "learn", 906, 1506)], category: category) == 0)
    precondition(
      ActivityAnalytics.focusTime(
        [
          session(1, "work", 0, 900), session(2, "social", 900, 901), session(3, "work", 901, 1801),
        ], category: category) == 0, "Nonproductive activity interrupts focus")
    precondition(
      ActivityAnalytics.focusTime(
        [
          session(1, "work", 0, 1500), session(2, "social", 1500, 1501),
          session(3, "learn", 1501, 3001),
        ], category: category) == 3000)
    precondition(
      ActivityAnalytics.focusTime(
        [session(1, "work", 0, 1200), session(2, "learn", 600, 1800)], category: category) == 1800,
      "Overlapping intervals never double count")
    precondition(
      ActivityAnalytics.focusTime(
        [session(1, "work", 0, 1000), session(2, "learn", 0, 1000)], category: category) == 0,
      "Duplicates cannot create a false qualifying stretch")
    let malformed = [
      session(1, "work", 20, 10), session(2, "work", .nan, 1000), session(3, "work", 0, .infinity),
    ]
    precondition(ActivityAnalytics.focusTime(malformed, category: category) == 0)
    precondition(ActivityAnalytics.switchCount(malformed) == 0)

    func interval(
      _ start: Double = 100, _ end: Double = 105, idle: Double = 2, limit: Double = 60,
      wasIdle: Bool = false
    ) -> DateInterval? {
      TrackingPolicy.interval(
        start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
        idleSeconds: idle, idleLimit: limit, wasIdle: wasIdle)
    }
    precondition(interval()?.duration == 5)
    precondition(interval(idle: 59.999)?.duration == 5)
    precondition(interval(idle: 60) == nil && interval(idle: 61) == nil)
    precondition(
      interval(wasIdle: true)?.duration == 2, "Resume only includes time since recent activity")
    precondition(
      interval(idle: 10, wasIdle: true)?.duration == 5, "Resume cannot extend before sample start")
    precondition(interval(idle: 0, wasIdle: true) == nil)
    precondition(interval(100, 115)?.duration == 15)
    precondition(
      interval(100, 115.01) == nil && interval(100, 1000) == nil,
      "Missed polls and laptop sleep are not active time")
    precondition(interval(105, 100) == nil && interval(100, 100) == nil)
    precondition(
      interval(idle: -1) == nil && interval(idle: .nan) == nil && interval(idle: .infinity) == nil)
    precondition(
      interval(limit: 0) == nil && interval(limit: -1) == nil && interval(limit: .nan) == nil
        && interval(limit: .infinity) == nil)
    precondition(interval(.nan, 105) == nil && interval(100, .infinity) == nil)
    print(
      "Analytics tests passed: app switches, domain changes, idle boundaries, focus thresholds, overlap normalization, and safe tracking resume."
    )
  }
}
