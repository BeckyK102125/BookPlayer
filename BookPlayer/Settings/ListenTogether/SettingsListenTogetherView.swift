//
//  SettingsListenTogetherView.swift
//  BookPlayer
//
//  Settings → Playback → Listen Together (addendum 2, "Both have the book").
//

import BookPlayerKit
import SwiftUI

/// "When someone doesn't have the book": two named options in an inline picker (both on screen and
/// reachable by swiping, no double negative as a toggle would have). The choice is saved on selection;
/// nothing is announced (VoiceOver speaks the selected state itself), there is nothing to cancel, and
/// back (or the two-finger scrub) simply goes back. Per device, applies to the next share.
struct SettingsListenTogetherView: View {
  @EnvironmentObject var theme: ThemeViewModel
  @AppStorage(ListenTogetherSharingMode.defaultsKey) private var mode: ListenTogetherSharingMode =
    ListenTogetherSharingMode.defaultMode
  /// "Speak error messages" (addendum 3, decision 8): off by default, per device.
  @AppStorage(ListenTogetherSpeaker.settingKey) private var speaksErrors = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Form {
      ThemedSection {
        Picker(selection: $mode) {
          ForEach(ListenTogetherSharingMode.allCases, id: \.self) { option in
            Text(option.title)
              .bpFont(.body)
              .foregroundStyle(theme.primaryColor)
              .fixedSize(horizontal: false, vertical: true)
              .tag(option)
          }
        } label: {
          Text("settings_listen_together_header".localized)
        }
        .pickerStyle(.inline)
        // labelsHidden keeps the label as the picker's name; no extra accessibilityLabel (it could be
        // applied to every option row of an inline picker and hide the option names).
        .labelsHidden()
      } header: {
        // Primary, not secondary: the themes' secondary colour is below 4.5:1 on the background in most
        // themes, and this header and footer are the only explanation of the two options.
        Text("settings_listen_together_header".localized)
          .bpFont(.subheadline)
          .foregroundStyle(theme.primaryColor)
      } footer: {
        Text("settings_listen_together_footer".localized)
          .bpFont(.footnote)
          .foregroundStyle(theme.primaryColor)
          .fixedSize(horizontal: false, vertical: true)
      }

      // Guidance B.1: the visible text is the toggle's label (no custom accessibilityLabel), so VoiceOver
      // reads "Speak error messages, switch button, off" and Voice Control matches it.
      ThemedSection {
        Toggle(isOn: $speaksErrors) {
          Text("settings_listen_together_speak_toggle".localized)
            .bpFont(.body)
            .foregroundStyle(theme.primaryColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        if speaksErrors {
          // B.2: lets the person check the voice and volume. Speaks even with VoiceOver on.
          Button {
            ListenTogetherSpeaker.shared.speakSample()
          } label: {
            Label {
              Text("settings_listen_together_speak_sample_button".localized)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "speaker.wave.2").accessibilityHidden(true)
            }
            .bpFont(.body)
            .foregroundStyle(theme.primaryColor)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("settings_listen_together_speak_sample_button".localized)
          .accessibilityIdentifier("listenTogether.hearSample")
        }
      } header: {
        Text("settings_listen_together_speak_header".localized)
          .bpFont(.subheadline)
          .foregroundStyle(theme.primaryColor)
      } footer: {
        Text("settings_listen_together_speak_footer".localized)
          .bpFont(.footnote)
          .foregroundStyle(theme.primaryColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      .animation(reduceMotion ? nil : .default, value: speaksErrors)
    }
    .scrollContentBackground(.hidden)
    .background(theme.systemBackgroundColor)
    .navigationTitle("settings_listen_together_title".localized)
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    SettingsListenTogetherView()
  }
  .environmentObject(ThemeViewModel())
}
