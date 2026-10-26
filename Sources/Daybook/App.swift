import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main struct DaybookApp: App {
  @StateObject private var model = AppModel()
  var body: some Scene {
    WindowGroup("Daybook", id: "main") {
      ContentView().environmentObject(model).frame(minWidth: 920, minHeight: 650)
    }
    .defaultSize(width: 1120, height: 780)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Daybook") { NSApplication.shared.orderFrontStandardAboutPanel() }
      }
      CommandMenu("Tracking") {
        Button(
          model.trackingEnabled ? "Stop tracking" : "Start tracking", action: model.toggleTracking)
        Button(model.paused ? "Resume" : "Pause", action: model.togglePause)
          .disabled(!model.trackingEnabled)
      }
    }
    MenuBarExtra {
      MenuContent().environmentObject(model)
    } label: {
      Label(
        model.trackingEnabled ? formatDuration(model.todayTotal) : "Daybook",
        systemImage: model.paused ? "pause.circle" : "circle.lefthalf.filled")
    }
  }
}

private struct MenuContent: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) var openWindow
  var body: some View {
    Text("Today · \(formatDuration(model.todayTotal))")
    Text(model.status)
    Divider()
    Button("Open Daybook") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button(model.trackingEnabled ? "Stop tracking" : "Start tracking", action: model.toggleTracking)
    if model.trackingEnabled {
      Button(model.paused ? "Resume tracking" : "Pause tracking", action: model.togglePause)
    }
    Divider()
    Button("Quit Daybook") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

func formatDuration(_ seconds: TimeInterval) -> String {
  if seconds > 0 && seconds < 60 { return "<1m" }
  let minutes = max(0, Int(seconds) / 60)
  return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

@MainActor final class AppModel: ObservableObject {
  @Published var page: Page = .today { didSet { refresh() } }
  @Published var day = Date() { didSet { refresh() } }
  @Published var paused = false
  @Published var trackingEnabled = false
  @Published var browserEnabled = false
  @Published var rows: [UsageItem] = []
  @Published var sessions: [ActivitySession] = []
  @Published var status = "Ready when you are · tracking is off"
  @Published var errorMessage: String?
  @Published var launchAtLogin = false
  @Published var todayTotal: TimeInterval = 0
  @Published var excludedApps = ""
  @Published var idleMinutes = 3
  @Published var videoSessions: [VideoSession] = []
  @Published var videoEnabled = true
  @Published var videoStatus = "Waiting for video extension setup"
  private var store: ActivityStore?
  private let tracker = ActivityTracker()
  private var refreshTimer: Timer?
  private var dataURL: URL!
  private let defaults = UserDefaults.standard
  private var pending: (bundle: String, name: String, domain: String?, start: Date, end: Date)?
  private var shuttingDownObserver: NSObjectProtocol?
  private var categoryCache: [String: Category] = [:]
  private var nameCache: [String: String] = [:]
  private var videoObserver: NSObjectProtocol?
  private var playbackLedger = PlaybackLedger()
  private var pairingCode = ""

  var activityTime: TimeInterval { rows.reduce(0) { $0 + $1.duration } }
  var foregroundTotal: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
  var videoTotal: TimeInterval {
    PlaybackMath.duration(videoSessions.map { DateInterval(start: $0.start, end: $0.end) })
  }
  var total: TimeInterval {
    PlaybackMath.duration(timelineSessions.map { DateInterval(start: $0.start, end: $0.end) })
  }
  var timelineSessions: [ActivitySession] {
    (sessions
      + videoSessions.map {
        ActivitySession(
          id: -$0.id, bundleID: "daybook.video", appName: "Video playback", domain: $0.domain,
          start: $0.start, end: $0.end)
      }).sorted { $0.start < $1.start }
  }
  var switchCount: Int { ActivityAnalytics.switchCount(sessions) }
  var focusTime: TimeInterval {
    ActivityAnalytics.focusTime(sessions, category: categoryForSession)
  }
  var bounds: (Date, Date) {
    let calendar = Calendar.current
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
    let start = calendar.date(byAdding: .day, value: page == .week ? -7 : -1, to: end)!
    return (start, end)
  }

  init() {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      dataURL = support.appendingPathComponent("Daybook", isDirectory: true)
      try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
      store = try ActivityStore(url: dataURL.appendingPathComponent("daybook.sqlite"))

    } catch { errorMessage = "Could not open local data: \(error.localizedDescription)" }
    trackingEnabled = defaults.bool(forKey: "trackingEnabled") && store != nil
    browserEnabled = defaults.bool(forKey: "browserEnabled")
    videoEnabled = defaults.object(forKey: "videoEnabled") as? Bool ?? true
    pairingCode = defaults.string(forKey: "videoPairingCode") ?? PlaybackProtocol.newPairingCode()
    defaults.set(pairingCode, forKey: "videoPairingCode")
    excludedApps = defaults.string(forKey: "excludedApps") ?? ""
    let savedIdle = defaults.integer(forKey: "idleMinutes")
    idleMinutes = [1, 2, 3, 5, 10].contains(savedIdle) ? savedIdle : 3
    tracker.exclusions = exclusionIDs
    tracker.idleLimit = Double(idleMinutes * 60)
    launchAtLogin = SMAppService.mainApp.status == .enabled
    tracker.enabled = trackingEnabled
    tracker.browserEnabled = browserEnabled
    tracker.onStatus = { [weak self] in if self?.trackingEnabled == true { self?.status = $0 } }
    tracker.onInterval = { [weak self] in
      self?.record(bundle: $0, name: $1, domain: $2, start: $3, end: $4)
    }
    tracker.onRecordingBreak = { [weak self] in self?.playbackLedger.clear() }
    videoObserver = DistributedNotificationCenter.default().addObserver(
      forName: PlaybackProtocol.notification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let object = notification.object as? String else { return }
      MainActor.assumeIsolated { self?.receivePlayback(object) }
    }
    tracker.onIdle = { [weak self] start, end in
      guard let self else { return }
      self.flush()
      do { try self.store?.removeLiveActivity(from: start, to: end) } catch {
        self.errorMessage = "Could not adjust idle time: \(error.localizedDescription)"
      }
    }
    refresh()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        if self?.trackingEnabled == true && self?.paused == false {
          self?.flush()
          self?.refresh()
        }
      }
    }
    shuttingDownObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.tracker.tick()
        self?.flush()
      }
    }
  }

  private func record(bundle: String, name: String, domain: String?, start: Date, end: Date) {
    if let p = pending, p.bundle == bundle, p.domain == domain,
      abs(start.timeIntervalSince(p.end)) < 0.5, end.timeIntervalSince(p.start) < 60
    {
      pending?.end = end
    } else {
      flush()
      pending = (bundle, name, domain, start, end)
    }
  }

  private func flush() {
    guard let p = pending else { return }
    do {
      try store?.append(
        bundleID: p.bundle, appName: p.name, domain: p.domain, start: p.start, end: p.end)
      pending = nil
    } catch {
      tracker.enabled = false
      trackingEnabled = false
      errorMessage =
        "Recording stopped because the local database could not save: \(error.localizedDescription)"
    }
  }

  func refresh() {
    guard let store else { return }
    do {
      let (start, end) = bounds
      let raw = try store.sessions(from: start, to: end)
      videoSessions = try store.videoSessions(from: start, to: end)
      categoryCache = Dictionary(
        uniqueKeysWithValues: Set(
          raw.map { $0.domain ?? $0.bundleID } + videoSessions.map(\.domain)
        ).map { ($0, store.category(for: $0)) })
      sessions = raw.map { s in
        ActivitySession(
          id: s.id, bundleID: s.bundleID, appName: appName(s.bundleID, fallback: s.appName),
          domain: s.domain, start: s.start, end: s.end)
      }
      rows = try store.usage(from: start, to: end).map { r in
        UsageItem(
          id: r.id, name: r.domain == nil ? appName(r.bundleID, fallback: r.name) : r.name,
          bundleID: r.bundleID, domain: r.domain, duration: r.duration, visits: r.visits,
          category: r.category)
      }
      var grouped: [String: [DateInterval]] = [:]
      func usageKey(_ value: String) -> String {
        let key = value.lowercased()
        return key.hasPrefix("www.") ? String(key.dropFirst(4)) : key
      }
      for session in sessions {
        grouped[usageKey(session.domain ?? session.bundleID), default: []].append(
          DateInterval(start: session.start, end: session.end))
      }
      for video in videoSessions {
        grouped[video.domain, default: []].append(DateInterval(start: video.start, end: video.end))
      }
      var metadata = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
      for video in videoSessions where metadata[video.domain] == nil {
        metadata[video.domain] = UsageItem(
          id: video.domain, name: video.domain, bundleID: "daybook.video", domain: video.domain,
          duration: 0, visits: 0, category: store.category(for: video.domain))
      }
      rows = grouped.compactMap { key, intervals in
        guard let item = metadata[key] else { return nil }
        let merged = PlaybackMath.merged(intervals)
        return UsageItem(
          id: item.id, name: item.name, bundleID: item.bundleID, domain: item.domain,
          duration: merged.reduce(0) { $0 + $1.duration }, visits: max(item.visits, merged.count),
          category: item.category)
      }.sorted { $0.duration > $1.duration }
      let today = Calendar.current.startOfDay(for: Date())
      let now = Date()
      let todayForeground = try store.sessions(from: today, to: now).map {
        DateInterval(start: $0.start, end: $0.end)
      }
      let todayVideo = try store.videoSessions(from: today, to: now).map {
        DateInterval(start: $0.start, end: $0.end)
      }
      todayTotal = PlaybackMath.duration(todayForeground + todayVideo)
    } catch { errorMessage = "Could not read local data: \(error.localizedDescription)" }
  }

  func toggleTracking() {
    guard store != nil else {
      errorMessage = "The local database is unavailable."
      return
    }
    tracker.tick()
    flush()
    playbackLedger.clear()
    trackingEnabled.toggle()
    paused = false
    tracker.paused = false
    tracker.enabled = trackingEnabled
    defaults.set(trackingEnabled, forKey: "trackingEnabled")
    status = trackingEnabled ? "Recording front app · on this Mac" : "Tracking is off"
    refresh()
  }

  private var exclusionIDs: Set<String> {
    Set(
      excludedApps.components(separatedBy: CharacterSet(charactersIn: ",\n")).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }.filter { !$0.isEmpty })
  }

  private func appName(_ bundleID: String, fallback: String) -> String {
    if let name = nameCache[bundleID] { return name }
    let name =
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      .map {
        FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
      } ?? fallback
    nameCache[bundleID] = name
    return name
  }

  func categoryForSession(_ session: ActivitySession) -> Category {
    categoryCache[session.domain ?? session.bundleID] ?? .other
  }

  func setIdleMinutes(_ minutes: Int) {
    guard [1, 2, 3, 5, 10].contains(minutes) else { return }
    tracker.tick()
    flush()
    idleMinutes = minutes
    tracker.idleLimit = Double(minutes * 60)
    defaults.set(minutes, forKey: "idleMinutes")
    status = "Idle cutoff set to \(minutes) minutes"
  }

  func saveExcludedApps(_ raw: String) {
    tracker.tick()
    flush()
    excludedApps = raw
    tracker.exclusions = exclusionIDs
    defaults.set(raw, forKey: "excludedApps")
    status = "Exclusions saved · applies to new activity"
  }

  func togglePause() {
    tracker.tick()
    flush()
    playbackLedger.clear()
    paused.toggle()
    tracker.paused = paused
    status = paused ? "Tracking paused" : "Recording front app · on this Mac"
    refresh()
  }

  private func receivePlayback(_ object: String) {
    let now = Date()
    guard videoEnabled, let packet = PlaybackProtocol.decode(object, code: pairingCode, now: now)
    else { return }
    guard tracker.canRecordVideo else {
      playbackLedger.clear()
      videoStatus = "Browser connected · recording is paused or off"
      return
    }
    if exclusionIDs.contains(where: { packet.domain == $0 || packet.domain.hasSuffix("." + $0) }) {
      playbackLedger.discard(packet.session)
      return
    }
    videoStatus =
      packet.playing ? "Video detected · \(packet.domain)" : "Video paused · \(packet.domain)"
    guard let interval = playbackLedger.consume(packet, now: now) else { return }
    do {
      try store?.appendVideo(domain: interval.domain, start: interval.start, end: interval.end)
    } catch { errorMessage = "Could not save video time: \(error.localizedDescription)" }
  }

  func setVideoEnabled(_ enabled: Bool) {
    videoEnabled = enabled
    defaults.set(enabled, forKey: "videoEnabled")
    playbackLedger.clear()
    videoStatus =
      enabled ? "Waiting for a playing video from the paired browser" : "Video tracking is off"
  }

  func copyVideoPairingCode() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pairingCode, forType: .string)
    videoStatus = "Pairing code copied · paste it in Daybook Video extension options"
  }

  func showVideoSetup() {
    guard let resource = Bundle.main.resourceURL else { return }
    NSWorkspace.shared.open(resource.appendingPathComponent("VideoExtension/Setup.html"))
  }

  func revealVideoExtension() {
    guard let resource = Bundle.main.resourceURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([
      resource.appendingPathComponent("VideoExtension")
    ])
  }

  func enableBrowserTracking() {
    browserEnabled.toggle()
    tracker.browserEnabled = browserEnabled
    defaults.set(browserEnabled, forKey: "browserEnabled")
    status =
      browserEnabled
      ? "Switch to a browser and allow Automation when macOS asks." : "Website tracking is off"
  }

  func setCategory(_ category: Category, for key: String) {
    do {
      try store?.setCategory(category, for: key)
      refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  func importTimecard() {
    let panel = NSOpenPanel()
    panel.title = "Import existing activity history"
    panel.message =
      "Choose the Timecard folder from Library/Application Support, or timecard.sqlite after quitting Timecard. Selecting the folder also allows reading its live journal. The original stays unchanged."
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      flush()
      var directory: ObjCBool = false
      FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      let source = directory.boolValue ? url.appendingPathComponent("timecard.sqlite") : url
      let count = try store?.importTimecard(from: source) ?? 0
      status = "Imported \(count) activity records · original unchanged"
      refresh()
    } catch {
      errorMessage =
        "Import failed: \(error.localizedDescription). Select the containing Timecard folder, or quit Timecard and choose its database again."
    }
  }

  func exportCSV() {
    flush()
    do {
      let (start, end) = bounds
      guard let csv = try store?.exportCSV(from: start, to: end) else { return }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "Daybook-\(dateKey(day)).csv"
      panel.allowedContentTypes = [.commaSeparatedText]
      if panel.runModal() == .OK, let url = panel.url {
        try csv.write(to: url, atomically: true, encoding: .utf8)
      }
    } catch { errorMessage = "Export failed: \(error.localizedDescription)" }
  }

  func revealData() { if let dataURL { NSWorkspace.shared.open(dataURL) } }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = SMAppService.mainApp.status == .enabled
      if enabled && !launchAtLogin {
        errorMessage = "Approve Daybook in System Settings → General → Login Items."
      }
    } catch {
      launchAtLogin = false
      errorMessage = "Start at login could not be changed: \(error.localizedDescription)"
    }
  }

  private func dateKey(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }
}
