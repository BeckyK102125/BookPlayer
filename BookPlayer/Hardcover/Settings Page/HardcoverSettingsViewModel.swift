//
//  HardcoverSettingsViewModel.swift
//  BookPlayer
//
//  Created by Jeremy Grenier on 6/27/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import AuthenticationServices
import BookPlayerKit
import Combine
import Get
import JellyfinAPI
import SwiftUI

@MainActor
final class HardcoverSettingsViewModel: HardcoverSettingsView.Model {
  private var hardcoverService: HardcoverServiceProtocol
  private let clientId: String

  init(hardcoverService: HardcoverServiceProtocol, clientId: String = HardcoverOAuth.clientId) {
    self.hardcoverService = hardcoverService
    self.clientId = clientId

    super.init(
      isSignedIn: hardcoverService.isSignedInWithOAuth,
      connectedUsername: hardcoverService.connectedUsername
    )
  }

  /// Shown as signed out right away: the sign-in is forgotten at once, but revoking it waits on the network
  @MainActor
  override func onLogOutTapped() {
    let hardcoverService = hardcoverService

    Task {
      await hardcoverService.disconnect()
    }

    isSignedIn = false
    connectedUsername = nil
  }

  @MainActor
  override func onSignInTapped(authenticate: @escaping (URL) async throws -> URL) async {
    // SR7-05: without a client id Hardcover's page can only show an error; say so here instead
    guard !clientId.isEmpty else {
      signInFailureMessage = "hardcover_sign_in_unavailable_message".localized
      signInFailed = true
      return
    }
    signInFailureMessage = "hardcover_sign_in_failed_message".localized
    isSigningIn = true
    defer { isSigningIn = false }

    do {
      try await hardcoverService.signIn(authenticate: authenticate)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      /// Closed by the user: nothing to report
    } catch {
      signInFailed = true
    }

    isSignedIn = hardcoverService.isSignedInWithOAuth
    connectedUsername = hardcoverService.connectedUsername
  }
}
