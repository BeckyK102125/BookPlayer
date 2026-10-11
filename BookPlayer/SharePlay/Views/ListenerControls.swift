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

/// A duration as VoiceOver reads it. `secondsToMinutes` returns an empty string under half a second,
/// which would make the value read "Elapsed , remaining …".
enum ListenerTimeText {
  static func spoken(_ interval: TimeInterval) -> String {
    let text = VoiceOverService.secondsToMinutes(interval)
    return text.isEmpty ? "listen_together_zero_seconds".localized : text
  }
}

/// What the position element shows and reads. While the group's place is not known yet, no time is
/// shown or read (a11y I2): a listener's own timeline is still at 0, which would look like the session
/// started at the beginning again.
@MainActor
enum ListenerPositionText {
  static func elapsed(for listener: ListenerPlayer) -> TimeInterval {
    min(max(listener.bookTime, 0), max(listener.manifest.duration, 0))
  }

  static func remaining(for listener: ListenerPlayer) -> TimeInterval {
    max(max(listener.manifest.duration, 0) - elapsed(for: listener), 0)
  }

  static func value(for listener: ListenerPlayer) -> String {
    if listener.isJoiningGroup { return "listen_together_finding_place".localized }
    return String.localizedStringWithFormat(
      "listen_together_time_value".localized,
      ListenerTimeText.spoken(elapsed(for: listener)),
      ListenerTimeText.spoken(remaining(for: listener)))
  }

  static func elapsedText(for listener: ListenerPlayer) -> String {
    listener.isJoiningGroup ? "listen_together_time_unknown".localized : TimeParser.formatTime(elapsed(for: listener))
  }

  static func remainingText(for listener: ListenerPlayer) -> String {
    listener.isJoiningGroup
      ? "listen_together_time_unknown".localized : "-" + TimeParser.formatTime(remaining(for: listener))
  }
}

/// The book position: one adjustable element. Swipe up or down moves 30 seconds, and VoiceOver reads
/// "Elapsed …, remaining …" after each step. The visible bar and times are hidden from VoiceOver so the
/// time is never read twice. The bar is read-only: dragging would send a seek for every tick.
struct ListenerPositionView: View {
  @ObservedObject var listener: ListenerPlayer

  /// A swipe on the position. While the group's place is being found it does nothing and says nothing:
  /// VoiceOver re-reads the value ("Finding the group's place") anyway (round 2, a11y M-a).
  @MainActor static func adjust(_ listener: ListenerPlayer, by seconds: TimeInterval) {
    guard !listener.isJoiningGroup else { return }
    listener.userSkip(by: seconds)
  }
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let duration = max(listener.manifest.duration, 0)
    let elapsed = ListenerPositionText.elapsed(for: listener)
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(spacing: 8))

    VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: duration > 0 ? elapsed / duration : 0)
        .tint(theme.primaryColor)
        .animation(nil, value: elapsed)
        // No bar while the place is unknown: an empty bar would say "at the beginning" (a11y I2).
        .opacity(listener.isJoiningGroup ? 0 : 1)
      layout {
        Text(ListenerPositionText.elapsedText(for: listener))
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
        Text(ListenerPositionText.remainingText(for: listener))
      }
      .bpFont(.footnote)
      .monospacedDigit()
      // Primary (A9): secondary is below 4.5:1 in most light themes.
      .foregroundStyle(theme.primaryColor)
    }
    .frame(minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("listen_together_position_title".localized)
    .accessibilityHint("listen_together_position_hint".localized)
    .accessibilityValue(ListenerPositionText.value(for: listener))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: Self.adjust(listener, by: ListenerSkip.seconds)
      case .decrement: Self.adjust(listener, by: -ListenerSkip.seconds)
      @unknown default: break
      }
    }
  }
}

/// Skip back 30, play/pause, skip forward 30. Media controls never mirror for right-to-left languages.
struct ListenerTransportRow: View {
  @ObservedObject var listener: ListenerPlayer
  /// For the play button's value while playback is held (C.1, C.2).
  @ObservedObject var service: SharePlaySessionService
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
      // "Waiting for the book" / "Waiting for the person sharing": why Play does nothing.
      .accessibilityValue(ListenTogetherStatus.waitingCaption(service.statusConditions) ?? "")
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
      // A refused press (waiting, finding the place) gets no "pressed" haptic (a11y M5).
      if !listener.refusesUserActions { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
      action()
    } label: {
      Image(systemName: systemName)
        .resizable()
        .scaledToFit()
        .frame(width: min(iconSize, 88), height: min(iconSize, 88))
        // Primary (A5): link is below 3:1 in four theme variants.
        .foregroundStyle(theme.primaryColor)
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
          // A7: a symbol with the text (decorative; the label and value are already right).
          Image(systemName: "gauge.with.dots.needle.67percent").accessibilityHidden(true)
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
      // Primary (A6, A7): link is below 4.5:1 in ten theme variants.
      .foregroundStyle(theme.primaryColor)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 44)
      .overlay(Capsule().stroke(theme.primaryColor, lineWidth: 1.5))
      .contentShape(Capsule())
  }
}
