import CoreGraphics
import Foundation

struct PlaybackRect: Codable, Equatable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var valid: Bool {
    [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
      && abs(x) < 100_000 && abs(y) < 100_000 && width < 32_000 && height < 32_000
  }
  var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  init(_ rect: CGRect) {
    self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
  }
}

struct BrowserPlaybackContext: Codable {
  var browserPID: Int32
  var window: PlaybackRect
  var regions: [PlaybackRect]
  var audible: Bool
  var pictureInPicture: Bool
  var pipWidth: Double
  var pipHeight: Double
  var valid: Bool {
    browserPID > 0 && window.valid && regions.count <= 16 && regions.allSatisfy(\.valid)
      && pipWidth.isFinite && pipHeight.isFinite && pipWidth >= 0 && pipHeight >= 0
      && pipWidth < 32_000 && pipHeight < 32_000
  }
}

struct WindowGeometry {
  let id: Int
  let pid: Int32
  let bounds: CGRect
  var alpha: Double = 1
  var layer: Int = 0
}

enum VisibilityMath {
  static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
    let overlap = rect.intersection(cover)
    guard !overlap.isNull && overlap.width > 0 && overlap.height > 0 else { return [rect] }
    return [
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
      CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
      CGRect(
        x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
      CGRect(
        x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
    ].filter { $0.width > 0 && $0.height > 0 }
  }

  static func visibleArea(
    _ surface: CGRect, windowIndex: Int, windows: [WindowGeometry], displays: [CGRect]
  ) -> Double {
    guard windows.indices.contains(windowIndex), surface.width > 0, surface.height > 0 else {
      return 0
    }
    let clipped = surface.intersection(windows[windowIndex].bounds)
    var regions = displays.map { clipped.intersection($0) }.filter {
      !$0.isNull && $0.width > 0 && $0.height > 0
    }
    for cover in windows.prefix(windowIndex) where cover.alpha >= 0.98 && cover.layer >= 0 {
      regions = regions.flatMap { subtract(cover.bounds, from: $0) }
      if regions.isEmpty { return 0 }
      if regions.count > 512 { return 0 }
    }
    return regions.reduce(0) { $0 + $1.width * $1.height }
  }

  static func isVisible(
    _ surface: CGRect, windowIndex: Int, windows: [WindowGeometry], displays: [CGRect]
  ) -> Bool {
    let area = surface.width * surface.height
    return area > 0
      && visibleArea(surface, windowIndex: windowIndex, windows: windows, displays: displays)
        >= max(400, area * 0.1)
  }

  static func matchingWindow(pid: Int32, bounds: CGRect, windows: [WindowGeometry]) -> Int? {
    windows.indices.filter { windows[$0].pid == pid }.min { a, b in
      distance(windows[a].bounds, bounds) < distance(windows[b].bounds, bounds)
    }.flatMap { distance(windows[$0].bounds, bounds) <= 60 ? $0 : nil }
  }
  private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
    abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
  }
}

enum MusicSites {
  static func isMusicApp(_ bundle: String) -> Bool {
    [
      "com.spotify.client", "com.apple.music", "com.apple.itunes", "com.tidal.desktop",
      "com.deezer.deezer-desktop", "com.amazon.music", "com.qobuz.qobuz", "com.roon.roon",
      "com.coppertino.vox", "com.swinsian.swinsian",
    ].contains(bundle.lowercased())
  }

  static let dedicated = [
    "music.youtube.com", "open.spotify.com", "music.apple.com", "soundcloud.com", "bandcamp.com",
    "deezer.com", "tidal.com", "music.amazon.com", "music.amazon.in", "music.amazon.co.uk",
    "qobuz.com", "pandora.com", "listen.tidal.com", "audiomack.com",
  ]
  static func matches(_ domain: String, among sites: [String]) -> Bool {
    sites.contains { domain == $0 || domain.hasSuffix("." + $0) }
  }
  static func isDedicated(_ domain: String) -> Bool { matches(domain, among: dedicated) }
  static func supportsBackgroundMusic(_ domain: String) -> Bool {
    isDedicated(domain) || matches(domain, among: ["youtube.com", "youtu.be"])
  }
  static func kind(domain: String, playing: Bool, visible: Bool, audible: Bool) -> MediaKind? {
    guard playing else { return nil }
    if isDedicated(domain) { return audible ? .music : nil }
    if visible { return .video }
    return audible && supportsBackgroundMusic(domain) ? .music : nil
  }
}
