import AppKit
import CoreAudio

struct AudioPlaybackSample {
  let source: String
  let bundleID: String
  let appName: String
  let audible: Bool
}

@MainActor protocol SystemAudioMonitoring: AnyObject {
  var onSamples: (([AudioPlaybackSample]) -> Void)? { get set }
  var onStatus: ((String) -> Void)? { get set }
  var enabled: Bool { get set }
  var exclusions: Set<String> { get set }
  func poll()
  func stop()
}

@MainActor enum SystemAudioFactory {
  static func make() -> any SystemAudioMonitoring {
    if #available(macOS 14.2, *) { return SystemAudioMonitor() }
    return UnavailableAudioMonitor()
  }
}

@MainActor private final class UnavailableAudioMonitor: SystemAudioMonitoring {
  var onSamples: (([AudioPlaybackSample]) -> Void)?
  var onStatus: ((String) -> Void)?
  var exclusions = Set<String>()
  var enabled = false {
    didSet { if enabled { onStatus?("All-app audio requires macOS 14.2 or newer.") } }
  }
  func poll() {}
  func stop() {}
}

/// Only a recent-sound timestamp crosses the audio callback boundary. Buffers
/// are inspected in place and are never copied, retained, written or uploaded.
private final class SoundActivity {
  private let lock = NSLock()
  private var lastSound: TimeInterval = -.infinity
  func mark() {
    guard lock.try() else { return }
    lastSound = ProcessInfo.processInfo.systemUptime
    lock.unlock()
  }
  var audible: Bool {
    lock.lock()
    defer { lock.unlock() }
    return ProcessInfo.processInfo.systemUptime - lastSound < 1.25
  }
}

@available(macOS 14.2, *) private final class AudioLevelTap {
  let activity = SoundActivity()
  private var tap: AudioObjectID = 0
  private var device: AudioObjectID = 0
  private var io: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "local.daybook.audio-level", qos: .userInitiated)

  init(process: AudioObjectID) throws {
    let description = CATapDescription(stereoMixdownOfProcesses: [process])
    description.name = "Daybook playback activity"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    do {
      try check(AudioHardwareCreateProcessTap(description, &tap))
      var format = AudioStreamBasicDescription()
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
      guard format.mFormatID == kAudioFormatLinearPCM,
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        [32, 64].contains(format.mBitsPerChannel)
      else { throw AudioError.unsupportedFormat }
      let config: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Daybook private level meter",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
      ]
      try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device))
      let activity = self.activity
      let float64 = format.mBitsPerChannel == 64
      try check(
        AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, data, _, _, _ in
          let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
          for buffer in buffers {
            guard let pointer = buffer.mData else { continue }
            let count = min(8192, Int(buffer.mDataByteSize) / (float64 ? 8 : 4))
            var sound = false
            if float64 {
              let samples = pointer.assumingMemoryBound(to: Double.self)
              for i in 0..<count where samples[i].isFinite && abs(samples[i]) > 0.0005 {
                sound = true
                break
              }
            } else {
              let samples = pointer.assumingMemoryBound(to: Float.self)
              for i in 0..<count where samples[i].isFinite && abs(samples[i]) > 0.0005 {
                sound = true
                break
              }
            }
            if sound {
              activity.mark()
              break
            }
          }
        })
      try check(AudioDeviceStart(device, io))
    } catch {
      stop()
      throw error
    }
  }
  private func check(_ status: OSStatus) throws {
    if status != noErr { throw AudioError.system(status) }
  }
  func stop() {
    if device != 0 {
      AudioDeviceStop(device, io)
      if let io { AudioDeviceDestroyIOProcID(device, io) }
      AudioHardwareDestroyAggregateDevice(device)
    }
    if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
    io = nil
    device = 0
    tap = 0
  }
  deinit { stop() }
  private enum AudioError: LocalizedError {
    case unsupportedFormat
    case system(OSStatus)
    var errorDescription: String? {
      switch self {
      case .unsupportedFormat: return "This audio output format cannot be measured safely."
      case .system(let status):
        return
          "System audio access is unavailable (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
      }
    }
  }
}

@available(macOS 14.2, *) @MainActor private final class SystemAudioMonitor: SystemAudioMonitoring {
  var onSamples: (([AudioPlaybackSample]) -> Void)?
  var onStatus: ((String) -> Void)?
  var exclusions = Set<String>()
  var enabled = false { didSet { if !enabled { stop() } else { failed.removeAll() } } }
  private struct Meter {
    let tap: AudioLevelTap
    let bundle: String
    let name: String
    let source: String
  }
  private var meters: [AudioObjectID: Meter] = [:]
  private var failed: [AudioObjectID: Date] = [:]
  private let browsers = [
    "com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
    "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera", "org.mozilla.firefox", "ai.perplexity.comet",
  ]

  func stop() {
    for meter in meters.values { meter.tap.stop() }
    meters.removeAll()
  }

  func poll() {
    guard enabled else { return }
    var address = property(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size < 65536
    else {
      onStatus?("This Mac did not provide audio process information.")
      return
    }
    guard size > 0 else {
      stop()
      onSamples?([])
      return
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = ids.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { return }
    var active = Set<AudioObjectID>()
    let now = Date()
    for id in ids {
      guard value(id, kAudioProcessPropertyIsRunningOutput) == 1,
        let rawPID = value(id, kAudioProcessPropertyPID), rawPID > 0,
        let app = NSRunningApplication(processIdentifier: Int32(bitPattern: rawPID)),
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
        let bundle = applicationIdentity(app),
        !exclusions.contains(bundle.0.lowercased()), !exclusions.contains(bundle.1.lowercased()),
        !browsers.contains(where: { bundle.0 == $0 || bundle.0.hasPrefix($0 + ".") })
      else { continue }
      active.insert(id)
      if meters[id] == nil, meters.count < 8, now.timeIntervalSince(failed[id] ?? .distantPast) > 30
      {
        do {
          meters[id] = Meter(
            tap: try AudioLevelTap(process: id), bundle: bundle.0, name: bundle.1,
            source: "audio:\(rawPID):\(id)")
          failed.removeValue(forKey: id)
        } catch {
          failed[id] = now
          onStatus?(error.localizedDescription)
        }
      }
    }
    for missing in Set(meters.keys).subtracting(active) {
      meters.removeValue(forKey: missing)?.tap.stop()
    }
    failed = failed.filter { now.timeIntervalSince($0.value) < 60 }
    let samples = meters.values.map {
      AudioPlaybackSample(
        source: $0.source, bundleID: $0.bundle, appName: $0.name, audible: $0.tap.activity.audible)
    }
    onSamples?(samples)
    if samples.contains(where: \.audible) {
      onStatus?("Sound detected · level measurement only")
    } else if !meters.isEmpty {
      onStatus?("Waiting for sound · allow System Audio Recording if asked")
    } else if failed.isEmpty {
      onStatus?("Waiting for playback from a native app")
    }
  }
  private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
  private func value(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = property(selector)
    var result: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : nil
  }
  private func applicationIdentity(_ app: NSRunningApplication) -> (String, String)? {
    // Audio may come from an Electron helper. Resolve its outer app locally.
    var url = app.bundleURL
    var outer = url
    while let parent = url?.deletingLastPathComponent(), parent.path != url?.path,
      parent.path != "/"
    {
      if parent.pathExtension == "app" { outer = parent }
      url = parent
    }
    guard let outer, let bundle = Bundle(url: outer)?.bundleIdentifier else { return nil }
    return (
      bundle,
      FileManager.default.displayName(atPath: outer.path).replacingOccurrences(of: ".app", with: "")
    )
  }
}
