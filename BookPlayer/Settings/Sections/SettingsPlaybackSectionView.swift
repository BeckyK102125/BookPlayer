//
//  SettingsPlaybackSectionView.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 19/7/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct SettingsPlaybackSectionView: View {
  @EnvironmentObject var theme: ThemeViewModel
  @AppStorage(ListenTogetherSharingMode.defaultsKey) private var listenTogetherMode: ListenTogetherSharingMode =
    ListenTogetherSharingMode.defaultMode

  var body: some View {
    ThemedSection {
      NavigationLink(value: SettingsScreen.controls) {
        Text("settings_controls_title")
          .bpFont(.body)
      }
      .settingsRowBackground(for: .controls)
      NavigationLink(value: SettingsScreen.autoplay) {
        Text("settings_autoplay_section_title".localized.localizedCapitalized)
          .bpFont(.body)
      }
      .settingsRowBackground(for: .autoplay)
      NavigationLink(value: SettingsScreen.autolock) {
        Text("settings_autlock_section_title")
          .bpFont(.body)
      }
      .settingsRowBackground(for: .autolock)
      NavigationLink(value: SettingsScreen.listenTogether) {
        Text("settings_listen_together_title".localized)
          .bpFont(.body)
      }
      .settingsRowBackground(for: .listenTogether)
      // The current choice in short form, so it is heard without opening the screen.
      .accessibilityValue(listenTogetherMode.shortValue)
    } header: {
      Text("settings_playback_title")
        .bpFont(.subheadline)
        .foregroundStyle(theme.secondaryColor)
    }
  }
}

#Preview {
  NavigationStack {
    Form {
      SettingsPlaybackSectionView()
    }
  }
  .environmentObject(ThemeViewModel())
}
