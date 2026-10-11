import SwiftUI
import UIKit

/// WCAG contrast helpers for Listen Together controls whose colour pairs the themes don't design for.
enum ListenTogetherContrast {
  /// WCAG 2 relative luminance of an sRGB colour (alpha ignored).
  static func luminance(_ color: UIColor) -> Double {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
    func channel(_ value: CGFloat) -> Double {
      let value = min(max(Double(value), 0), 1)
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }

  /// Contrast ratio between two colours, from 1 to 21.
  static func ratio(_ first: UIColor, _ second: UIColor) -> Double {
    let (a, b) = (luminance(first), luminance(second))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// A colour `fraction` of the way from `color` to `target` (sRGB).
  static func blend(_ color: UIColor, toward target: UIColor, fraction: Double) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    let f = CGFloat(min(max(fraction, 0), 1))
    return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: 1)
  }

  /// Whether a switch's on-track `track` is visible (at least 3:1 against `row`) and its white thumb is
  /// visible on it (at least 3:1), WCAG 1.4.11.
  static func isVisibleToggleTrack(_ track: UIColor, on row: UIColor) -> Bool {
    ratio(track, row) >= 3 && ratio(.white, track) >= 3
  }

  /// The on-track colour for a switch on `row` (a11y I6): the link colour, else the primary colour,
  /// else the link colour darkened or lightened step by step until both the track and the thumb pass.
  static func toggleTint(link: UIColor, primary: UIColor, row: UIColor) -> UIColor {
    var candidates = [link, primary]
    for step in 1..<20 {
      let fraction = Double(step) / 20
      candidates.append(blend(link, toward: .black, fraction: fraction))
      candidates.append(blend(link, toward: .white, fraction: fraction))
    }
    return candidates.first { isVisibleToggleTrack($0, on: row) } ?? primary
  }

  /// The candidate that contrasts most with `fill`.
  static func bestLabel(on fill: UIColor, from candidates: [UIColor]) -> UIColor? {
    candidates.max { ratio($0, fill) < ratio($1, fill) }
  }
}

extension ThemeViewModel {
  /// Text colour for a button filled with the link colour: the theme's background or primary colour,
  /// whichever reads better on it in the current appearance.
  func labelColorOnLink(for scheme: ColorScheme) -> Color {
    let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
    let fill = theme.linkColor.resolvedColor(with: traits)
    let candidates = [theme.systemBackgroundColor, theme.primaryColor].map { $0.resolvedColor(with: traits) }
    return Color(ListenTogetherContrast.bestLabel(on: fill, from: candidates) ?? theme.systemBackgroundColor)
  }
}

extension ThemeViewModel {
  /// The "Speak error messages" switch's tint on the theme's background, in the current appearance.
  func listenTogetherToggleTint(for scheme: ColorScheme) -> Color {
    let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
    return Color(ListenTogetherContrast.toggleTint(
      link: theme.linkColor.resolvedColor(with: traits),
      primary: theme.primaryColor.resolvedColor(with: traits),
      row: theme.systemBackgroundColor.resolvedColor(with: traits)))
  }
}
