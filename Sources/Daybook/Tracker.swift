import AppKit
import CoreGraphics

/// Samples app identity and idle duration. It never installs an input event tap.
@MainActor final class ActivityTracker {
  var onInterval: ((String, String, String?, Date, Date) -> Void)?
  var onIdle: ((Date, Date) -> Void)?
  var onRecordingBreak: (() -> Void)?
  var canRecordVideo: Bool { enabled && !paused && !sleeping }
  var onStatus: ((String) -> Void)?
  var enabled = false {
    didSet {
      runStarted = Date()
      reset()
    }
  }
  var paused = false {
    didSet {
      runStarted = Date()
      reset()
    }
  }
  var browserEnabled = false {
    didSet {
      domain = nil
      deniedBrowsers.removeAll()
    }
  }
  var exclusions = Set<String>()
  var idleLimit: TimeInterval = 180
  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var lastTick = Date()
  private var runStarted = Date()
  private var wasIdle = false
  private var lastProbe = Date.distantPast
  private var currentID = ""
  private var currentName = ""
  private var domain: String?
  private var probing = false
  private var deniedBrowsers = Set<String>()
  private var sleeping = false
  private let browserQueue = DispatchQueue(label: "local.daybook.browser")
  private let browsers: [String: Bool] = [
    "com.apple.Safari": true, "com.google.Chrome": false,
    "company.thebrowser.Browser": false, "com.brave.Browser": false,
    "com.microsoft.edgemac": false, "company.thebrowser.dia": false,
    "com.vivaldi.Vivaldi": false, "com.operasoftware.Opera": false,
    "ai.perplexity.comet": false,
  ]

  init() {
    let nc = NSWorkspace.shared.notificationCenter
    observers.append(
      nc.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick(switching: true) }
      })
    for name in [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.screensDidSleepNotification,
    ] {
      observers.append(
        nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.tick()
            self?.sleeping = true
            self?.onRecordingBreak?()
          }
        })
    }
    for name in [
      NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
      NSWorkspace.screensDidWakeNotification,
    ] {
      observers.append(
        nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.sleeping = false
            self?.reset()
          }
        })
    }
    timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer!, forMode: .common)
  }

  private func reset() {
    lastTick = Date()
    domain = nil
    wasIdle = false
    let app = NSWorkspace.shared.frontmostApplication
    currentID = app?.bundleIdentifier ?? ""
    currentName = app?.localizedName ?? currentID
  }

  private func excluded(bundleID: String, domain: String?) -> Bool {
    let bundle = bundleID.lowercased()
    if exclusions.contains(bundle) || exclusions.contains(currentName.lowercased()) { return true }
    guard let domain = domain?.lowercased() else { return false }
    return exclusions.contains { root in domain == root || domain.hasSuffix("." + root) }
  }

  func tick(switching: Bool = false) {
    let now = Date()
    defer { lastTick = now }
    guard enabled, !paused, !sleeping else {
      onStatus?(paused ? "Tracking paused" : "Tracking is off")
      return
    }
    // kCGAnyInputEventType is UInt32.max; .null would measure null events,
    // not keyboard/mouse activity, and incorrectly mark an active Mac idle.
    let idle = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    if !wasIdle, idle.isFinite, idle >= idleLimit {
      let cutoff = max(runStarted, now.addingTimeInterval(-idle))
      if cutoff < now { onIdle?(cutoff, now) }
    }
    if let interval = TrackingPolicy.interval(
      start: lastTick, end: now, idleSeconds: idle, idleLimit: idleLimit, wasIdle: wasIdle),
      !currentID.isEmpty, !excluded(bundleID: currentID, domain: domain)
    {
      onInterval?(currentID, currentName, domain, interval.start, interval.end)
    }
    wasIdle = idle >= idleLimit
    guard let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier
    else {
      currentID = ""
      domain = nil
      return
    }
    if id != currentID || switching { domain = nil }
    currentID = id
    currentName = front.localizedName ?? id
    if wasIdle {
      onStatus?("Away · inactive time excluded")
      return
    }
    if excluded(bundleID: id, domain: domain) {
      onStatus?("Excluded activity · not recording")
      // An excluded site can become another tab in the same browser.
      // Keep probing domains so tracking can resume when that happens.
      if exclusions.contains(id.lowercased()) || exclusions.contains(currentName.lowercased()) {
        return
      }
    } else {
      onStatus?("Recording \(domain ?? currentName) · on this Mac")
    }
    if browserEnabled, let safari = browsers[id], !probing, !deniedBrowsers.contains(id),
      now.timeIntervalSince(lastProbe) >= 2
    {
      lastProbe = now
      probeBrowser(id: id, safari: safari)
    }
  }

  private func probeBrowser(id: String, safari: Bool) {
    probing = true
    let statement =
      safari ? "URL of current tab of front window" : "URL of active tab of front window"
    let script =
      "tell application id \"\(id)\"\nif (count of windows) > 0 then return \(statement)\nend tell"
    browserQueue.async { [weak self] in
      var error: NSDictionary?
      let url = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
      let host = url.flatMap { URL(string: $0) }.flatMap { u in
        ["http", "https"].contains(u.scheme?.lowercased() ?? "") ? u.host?.lowercased() : nil
      }
      let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
      DispatchQueue.main.async {
        guard let self else { return }
        self.probing = false
        if self.currentID == id, self.browserEnabled { self.domain = host }
        if denied {
          self.deniedBrowsers.insert(id)
          self.onStatus?("Browser access denied. App tracking still works.")
        }
      }
    }
  }
}
