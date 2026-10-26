import AppKit

/// Explicit adapters keep an open player from being mistaken for active playback.
@MainActor final class NativePlayback {
  var onSamples: (([NativeMediaSample]) -> Void)?
  var onStatus: ((String) -> Void)?
  var enabled = false {
    didSet {
      generation += 1
      denied.removeAll()
    }
  }
  private var busy = false
  private var generation = 0
  private var denied = Set<String>()
  private let queue = DispatchQueue(label: "local.daybook.native-media")
  private let supported = [
    "com.spotify.client", "com.apple.Music", "com.apple.QuickTimePlayerX", "org.videolan.vlc",
  ]

  func poll() {
    guard enabled, !busy else { return }
    let running = NSWorkspace.shared.runningApplications.compactMap {
      app -> (String, String, Int32)? in
      guard let id = app.bundleIdentifier, supported.contains(id), !denied.contains(id) else {
        return nil
      }
      return (id, app.localizedName ?? id, app.processIdentifier)
    }
    guard !running.isEmpty else {
      onSamples?([])
      return
    }
    busy = true
    let requested = generation
    queue.async { [weak self] in
      var samples: [NativeMediaSample] = []
      var deniedIDs: [String] = []
      var unavailable: [String] = []
      for (id, name, pid) in running {
        var error: NSDictionary?
        let result = NSAppleScript(source: Self.script(id))?.executeAndReturnError(&error)
        if (error?[NSAppleScript.errorNumber] as? Int) == -1743 { deniedIDs.append(id) }
        if let code = error?[NSAppleScript.errorNumber] as? Int, code != -1743 {
          unavailable.append("\(name) unavailable (\(code))")
        }
        guard error == nil, let result else { continue }
        for i in 1...max(1, result.numberOfItems) where result.numberOfItems > 0 {
          guard let row = result.atIndex(i), row.numberOfItems >= 6,
            let source = row.atIndex(1)?.stringValue
          else { continue }
          let bounds: CGRect?
          if let b = row.atIndex(7), b.numberOfItems == 4 {
            let x = b.atIndex(1)!.doubleValue
            let y = b.atIndex(2)!.doubleValue
            bounds = CGRect(
              x: x, y: y, width: b.atIndex(3)!.doubleValue - x,
              height: b.atIndex(4)!.doubleValue - y)
          } else {
            bounds = nil
          }
          samples.append(
            NativeMediaSample(
              source: "native:\(pid):\(source)", bundleID: id, appName: name, pid: pid,
              playing: row.atIndex(2)?.booleanValue ?? false,
              position: row.atIndex(3)?.doubleValue ?? .nan,
              audio: row.atIndex(4)?.booleanValue ?? false,
              video: row.atIndex(5)?.booleanValue ?? false, bounds: bounds))
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy = false
        guard self.enabled, self.generation == requested else { return }
        self.denied.formUnion(deniedIDs)
        if self.denied.isEmpty {
          self.onStatus?(unavailable.joined(separator: " · "))
        } else {
          self.onStatus?(
            "Allow player access in System Settings → Privacy & Security → Automation.")
        }
        self.onSamples?(samples)
      }
    }
  }

  nonisolated static func script(_ id: String) -> String {
    let body: String
    switch id {
    case "com.spotify.client":
      body =
        "return {{\"player\", (player state is playing), player position, (sound volume > 0), false, 0}}"
    case "com.apple.Music":
      body =
        "return {{\"player\", (player state is playing), player position, ((not mute) and sound volume > 0), false, 0}}"
    case "org.videolan.vlc":
      // Only the file type leaves this script. Never retain the media path or title.
      // Use VLC's published property codes: its external scripting terminology
      // is not always available to an AppleScript compiled inside the sandbox.
      body = """
        if not («property AAPL») then return {}
        set p to «property AAPA»
        set isVideo to false
        set isAudio to false
        ignoring case
          repeat with ext in {".mp4", ".mkv", ".mov", ".m4v", ".webm", ".avi", ".ts", ".m2ts", ".mpeg", ".mpg", ".vob", ".flv", ".ogv"}
            if p ends with (ext as text) then set isVideo to true
          end repeat
          repeat with ext in {".mp3", ".m4a", ".aac", ".flac", ".wav", ".aif", ".aiff", ".opus", ".ogg", ".oga", ".alac", ".wma"}
            if p ends with (ext as text) then set isAudio to true
          end repeat
        end ignoring
        return {{"player", «property AAPL», «property AACT», ((not «property AAMU») and «property AAAV» > 0 and isAudio), isVideo, 0}}
        """
    default:
      body = """
        set rows to {}
        repeat with w in windows
          try
            set d to document of w
            set dims to natural dimensions of d
            set isVideo to (item 1 of dims > 0 and item 2 of dims > 0)
            set sourceID to (id of w) as text
            set end of rows to {sourceID, playing of d, current time of d, ((not muted of d) and audio volume of d > 0 and not isVideo), isVideo, 0, bounds of w}
          end try
        end repeat
        return rows
        """
    }
    return
      "with timeout of 2 seconds\ntell application id \"\(id)\"\n\(body)\nend tell\nend timeout"
  }
}
