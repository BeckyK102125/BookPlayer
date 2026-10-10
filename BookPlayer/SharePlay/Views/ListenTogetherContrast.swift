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
