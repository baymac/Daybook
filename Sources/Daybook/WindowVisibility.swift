import AppKit
import CoreAudio
import CoreGraphics

@MainActor final class WindowVisibility {
  private var lastSnapshot = Date.distantPast
  private var nativeWindowIDs: [String: Int] = [:]
  private(set) var windows: [WindowGeometry] = []
  private(set) var displays: [CGRect] = []

  func refresh(now: Date = Date()) {
    guard now.timeIntervalSince(lastSnapshot) >= 0.5 else { return }
    lastSnapshot = now
    // Read geometry only. Never request pixels, window titles, or screen-recording access.
    let raw =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    windows = raw.compactMap { item in
      guard let id = item[kCGWindowNumber as String] as? Int,
        let pid = item[kCGWindowOwnerPID as String] as? Int32,
        let bounds = item[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        let alpha = item[kCGWindowAlpha as String] as? Double,
        let layer = item[kCGWindowLayer as String] as? Int,
        layer >= 0, alpha > 0, rect.width > 1, rect.height > 1
      else { return nil }
      return WindowGeometry(id: id, pid: pid, bounds: rect, alpha: alpha, layer: layer)
    }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    if CGGetActiveDisplayList(count, &ids, &count) == .success {
      displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    } else {
      displays = []
    }
  }

  func visibleBrowserVideo(_ context: BrowserPlaybackContext) -> Bool {
    refresh()
    guard context.valid else { return false }
    if context.pictureInPicture, context.pipWidth > 0, context.pipHeight > 0 {
      let candidates = windows.indices.filter {
        let window = windows[$0]
        return window.pid == context.browserPID && window.layer > 0
          && abs(window.bounds.width - context.pipWidth) < 80
          && abs(window.bounds.height - context.pipHeight) < 80
      }
      return candidates.contains {
        VisibilityMath.isVisible(
          windows[$0].bounds, windowIndex: $0, windows: windows, displays: displays)
      }
    }
    guard
      let index = VisibilityMath.matchingWindow(
        pid: context.browserPID, bounds: context.window.cgRect, windows: windows)
    else { return false }
    return context.regions.contains {
      VisibilityMath.isVisible($0.cgRect, windowIndex: index, windows: windows, displays: displays)
    }
  }

  func visibleNativeVideo(pid: Int32, bounds: CGRect?) -> Bool {
    refresh()
    guard let bounds,
      let index = VisibilityMath.matchingWindow(pid: pid, bounds: bounds, windows: windows)
    else { return false }
    let surface = bounds.insetBy(dx: 4, dy: 28)
    return VisibilityMath.isVisible(
      surface, windowIndex: index, windows: windows, displays: displays)
  }

  func resetNativeWindows() { nativeWindowIDs.removeAll() }

  func nativeVideoBounds(pid: Int32, source: String) -> CGRect? {
    let raw =
      CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let candidates: [(Int, CGRect)] = raw.compactMap { item in
      guard (item[kCGWindowOwnerPID as String] as? Int32) == pid,
        (item[kCGWindowLayer as String] as? Int) == 0,
        let id = item[kCGWindowNumber as String] as? Int,
        let bounds = item[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 200,
        rect.height > 150
      else { return nil }
      return (id, rect)
    }
    if let id = nativeWindowIDs[source], let found = candidates.first(where: { $0.0 == id }) {
      return found.1
    }
    guard let largest = candidates.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })
    else { return nil }
    nativeWindowIDs[source] = largest.0
    return largest.1
  }

  static func outputIsMuted() -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
      device != 0
    else { return false }
    address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var mute: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute != 0 {
      return true
    }
    address.mSelector = kAudioDevicePropertyVolumeScalar
    var volume: Float32 = 1
    size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
      && volume == 0
  }
}
