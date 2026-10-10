import BookPlayerKit
import SwiftUI

/// The listener's skips are always 30 seconds, whatever the main player's skip settings are.
enum ListenerSkip {
  static let seconds: TimeInterval = 30

  static var backLabel: String {
    String.localizedStringWithFormat("voiceover_rewind_time".localized, VoiceOverService.secondsToMinutes(seconds))
  }

  static var forwardLabel: String {
    String.localizedStringWithFormat("voiceover_forward_time".localized, VoiceOverService.secondsToMinutes(seconds))
  }
}

/// The book position: one adjustable element. Swipe up or down moves 30 seconds, and VoiceOver reads
/// "Elapsed …, remaining …" after each step. The visible bar and times are hidden from VoiceOver so the
/// time is never read twice. The bar is read-only: dragging would send a seek for every tick.
struct ListenerPositionView: View {
  @ObservedObject var listener: ListenerPlayer
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let duration = max(listener.manifest.duration, 0)
    let elapsed = min(max(listener.bookTime, 0), duration)
    let remaining = max(duration - elapsed, 0)
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(spacing: 8))

    VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: duration > 0 ? elapsed / duration : 0)
        .tint(theme.linkColor)
        .animation(nil, value: elapsed)
      layout {
        Text(TimeParser.formatTime(elapsed))
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
        Text("-" + TimeParser.formatTime(remaining))
      }
      .bpFont(.footnote)
      .monospacedDigit()
      .foregroundStyle(theme.secondaryColor)
    }
    .frame(minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("listen_together_position_title".localized)
    .accessibilityHint("listen_together_position_hint".localized)
    .accessibilityValue(
      String.localizedStringWithFormat(
        "listen_together_time_value".localized,
        VoiceOverService.secondsToMinutes(elapsed),
        VoiceOverService.secondsToMinutes(remaining)))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: listener.userSkip(by: ListenerSkip.seconds)
      case .decrement: listener.userSkip(by: -ListenerSkip.seconds)
      @unknown default: break
      }
    }
  }
}

/// Skip back 30, play/pause, skip forward 30. Media controls never mirror for right-to-left languages.
struct ListenerTransportRow: View {
  @ObservedObject var listener: ListenerPlayer
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 44

  var body: some View {
    HStack(spacing: 16) {
      button(systemName: "gobackward.30", label: ListenerSkip.backLabel, identifier: "listenTogether.skipBack") {
        listener.userSkip(by: -ListenerSkip.seconds)
      }
      button(
        systemName: listener.isPlaying ? "pause.fill" : "play.fill",
        label: listener.isPlaying ? "pause_title".localized : "play_title".localized,
        identifier: "listenTogether.playPause"
      ) {
        listener.userTogglePlay()
      }
      .accessibilityAddTraits(.startsMediaSession)
      .animation(reduceMotion ? nil : .default, value: listener.isPlaying)
      button(systemName: "goforward.30", label: ListenerSkip.forwardLabel, identifier: "listenTogether.skipForward") {
        listener.userSkip(by: ListenerSkip.seconds)
      }
    }
    .frame(maxWidth: 400)
    .environment(\.layoutDirection, .leftToRight)
  }

  private func button(
    systemName: String, label: String, identifier: String, action: @escaping () -> Void
  ) -> some View {
    Button {
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      action()
    } label: {
      Image(systemName: systemName)
        .resizable()
        .scaledToFit()
        .frame(width: min(iconSize, 88), height: min(iconSize, 88))
        .foregroundStyle(theme.linkColor)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }
}

/// Chapters and speed. Side by side, or stacked at accessibility text sizes.
struct ListenerExtrasRow: View {
  @ObservedObject var listener: ListenerPlayer
  let showChapters: () -> Void
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

  static func number(_ rate: Float) -> String {
    rate.formatted(.number.precision(.fractionLength(0...2)))
  }

  /// "Normal speed" for 1, otherwise "1.5 times" (never "1 times").
  static func spokenRate(_ rate: Float) -> String {
    if rate == 1 { return "listen_together_speed_normal".localized }
    return String.localizedStringWithFormat("listen_together_speed_value".localized, number(rate))
  }

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 12))
      : AnyLayout(HStackLayout(spacing: 12))
    layout {
      if !listener.manifest.chapters.isEmpty {
        Button(action: showChapters) {
          pill {
            Image(systemName: "list.bullet").accessibilityHidden(true)
            Text("chapters_title".localized)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("listenTogether.chapters")
      }

      Menu {
        Picker(
          "listen_together_speed_title".localized,
          selection: Binding(get: { listener.rate }, set: { listener.userSetRate($0) })
        ) {
          ForEach(Self.rates, id: \.self) { rate in
            Text(Self.spokenRate(rate)).tag(rate)
          }
        }
        .pickerStyle(.inline)
      } label: {
        pill {
          Text("listen_together_speed_title".localized)
          Text(Self.number(listener.rate) + "×")
        }
      }
      .accessibilityLabel("listen_together_speed_title".localized)
      .accessibilityValue(Self.spokenRate(listener.rate))
      .accessibilityIdentifier("listenTogether.speed")
    }
  }

  private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 6) { content() }
      .bpFont(.body)
      .foregroundStyle(theme.linkColor)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 44)
      .overlay(Capsule().stroke(theme.linkColor, lineWidth: 1.5))
      .contentShape(Capsule())
  }
}
