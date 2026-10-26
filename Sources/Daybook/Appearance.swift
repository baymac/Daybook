import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
  var nativeAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

/// Shared adaptive colors keep charts, popovers and native windows in the same palette.
enum Paper {
  static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color
  {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
      })
  }
  static let background = adaptive((0.965, 0.956, 0.933), (0.105, 0.115, 0.110))
  static let sidebar = adaptive((0.935, 0.925, 0.900), (0.080, 0.090, 0.085))
  static let surface = adaptive((0.990, 0.985, 0.973), (0.145, 0.160, 0.150))
  static let ink = adaptive((0.17, 0.21, 0.20), (0.91, 0.92, 0.88))
  static let secondary = adaptive((0.43, 0.46, 0.43), (0.65, 0.69, 0.65))
  static let orange = adaptive((0.82, 0.36, 0.18), (0.96, 0.58, 0.38))
  static let teal = adaptive((0.22, 0.46, 0.42), (0.48, 0.75, 0.66))
  static let controlAccent = adaptive((0.22, 0.46, 0.42), (0.23, 0.48, 0.41))
  static let selectionInk = adaptive((1, 1, 1), (0.07, 0.14, 0.11))
  static let border = adaptive((0.17, 0.21, 0.20), (0.70, 0.76, 0.70))
}
