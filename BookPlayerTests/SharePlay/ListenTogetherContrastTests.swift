@testable import BookPlayer
import UIKit
import XCTest

/// R40/R41: every Listen Together text, icon and button colour pair passes in all 22 theme variants
/// (11 themes, light and dark) from Themes.json. The pairs used, each on the background it is drawn on:
/// the theme's primary colour on its system background (status text and icons, the session button's
/// label and outline, Not Now, the transport icons, Chapters, Speed, and the Settings rows "Speak error
/// messages" and "Hear a Sample", which are drawn on the system background since fix round 1), the
/// background colour on a primary fill (Join), and the switch's on-track and thumb.
final class ListenTogetherContrastTests: XCTestCase {
  private struct Variant {
    let name: String
    let primary: UIColor
    let background: UIColor
    let link: UIColor
  }

  private func variants() throws -> [Variant] {
    let bundles = [Bundle.main, Bundle(for: SharePlaySessionService.self)]
    let url = try XCTUnwrap(bundles.lazy.compactMap { $0.url(forResource: "Themes", withExtension: "json") }.first)
    let themes = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    var result: [Variant] = []
    for theme in themes {
      let title = try XCTUnwrap(theme["title"] as? String)
      for mode in ["light", "dark"] {
        let primary = try XCTUnwrap(theme["\(mode)PrimaryHex"] as? String)
        let background = try XCTUnwrap(theme["\(mode)SystemBackgroundHex"] as? String)
        let link = try XCTUnwrap(theme["\(mode)AccentHex"] as? String)
        result.append(Variant(
          name: "\(title) \(mode)", primary: color(primary), background: color(background), link: color(link)))
      }
    }
    return result
  }

  private func color(_ hex: String) -> UIColor {
    let value = UInt32(hex, radix: 16) ?? 0
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  func testThereAreTwentyTwoVariants() throws {
    XCTAssertEqual(try variants().count, 22)
  }

  func testPrimaryOnBackgroundPassesTextAndShapeLevelsEverywhere() throws {
    for variant in try variants() {
      let ratio = ListenTogetherContrast.ratio(variant.primary, variant.background)
      XCTAssertGreaterThanOrEqual(ratio, 4.5, "text: \(variant.name) \(ratio)")
      XCTAssertGreaterThanOrEqual(ratio, 3.0, "icon, outline: \(variant.name) \(ratio)")
    }
  }

  func testJoinLabelOnPrimaryFillAndFillOnBackground() throws {
    for variant in try variants() {
      // Join: label in the background colour on a primary fill, the fill against the background.
      XCTAssertGreaterThanOrEqual(
        ListenTogetherContrast.ratio(variant.background, variant.primary), 4.5, "label: \(variant.name)")
      XCTAssertGreaterThanOrEqual(
        ListenTogetherContrast.ratio(variant.primary, variant.background), 3.0, "fill: \(variant.name)")
    }
  }

  /// a11y I6: the "Speak error messages" switch is visible in every variant: its on-track at least 3:1
  /// on the row and the white thumb at least 3:1 on the track.
  func testToggleTintIsVisibleEverywhere() throws {
    for variant in try variants() {
      let tint = ListenTogetherContrast.toggleTint(link: variant.link, primary: variant.primary, row: variant.background)
      XCTAssertGreaterThanOrEqual(ListenTogetherContrast.ratio(tint, variant.background), 3, "track: \(variant.name)")
      XCTAssertGreaterThanOrEqual(ListenTogetherContrast.ratio(.white, tint), 3, "thumb: \(variant.name)")
    }
  }

  /// a11y N2: the checkmark of the chosen "When someone doesn't have the book" option is drawn in primary
  /// on the system background row.
  func testPickerCheckmarkOnTheSettingsRow() throws {
    for variant in try variants() {
      XCTAssertGreaterThanOrEqual(
        ListenTogetherContrast.ratio(variant.primary, variant.background), 3.0, "checkmark: \(variant.name)")
    }
  }
}
