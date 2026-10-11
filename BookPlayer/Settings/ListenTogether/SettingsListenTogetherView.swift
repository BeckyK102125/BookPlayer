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
