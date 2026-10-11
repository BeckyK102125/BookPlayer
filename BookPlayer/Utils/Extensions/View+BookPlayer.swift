//
//  View+BookPlayer.swift
//  BookPlayer
//
//  Created by Lysann Schlegel on 2024-11-10.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import SwiftUI

// MARK: - Keyboard Observer

final class KeyboardObserver: ObservableObject {
  @Published var isKeyboardVisible = false

  private var cancellables = Set<AnyCancellable>()

  init() {
    NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.isKeyboardVisible = true
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.isKeyboardVisible = false
      }
      .store(in: &cancellables)
  }
}

extension View {
  @ViewBuilder
  func defaultFormBackground() -> some View {
    scrollContentBackground(.hidden)
  }
}

extension View {
  /// Applies a BPFont style with automatic Dynamic Type support
  /// On iOS: Uses native SwiftUI fonts that respond to system Dynamic Type
  /// On macOS: Applies manual scaling based on user's text size preference
  func bpFont(_ style: BPFont) -> some View {
    self.modifier(BPFontModifier(style: style))
  }
}

// MARK: - BPFont Modifier

/// Applies BPFont with platform-specific scaling
/// iOS: Native Dynamic Type via SwiftUI text styles
/// macOS: Manual scaling using user preference from Settings
struct BPFontModifier: ViewModifier {
  let style: BPFont

  @AppStorage(Constants.UserDefaults.macOSTextScale)
  private var textScaleIndex: Double = 0.0

  private var isMacOS: Bool {
    ProcessInfo.processInfo.isiOSAppOnMac
  }

  /// Scale factor for macOS (1.0 to 1.6 based on slider position 0-6)
  private var macOSScaleFactor: CGFloat {
    1.0 + (textScaleIndex * 0.1)
  }

  func body(content: Content) -> some View {
    if isMacOS {
      content.font(style.scaledFont(by: macOSScaleFactor))
    } else {
      content.font(style.font)
    }
  }
}

extension View {
  func disabledWithOpacity(_ condition: Bool, opacity: Double = 0.5) -> some View {
    self
      .disabled(condition)
      .opacity(condition ? opacity : 1)
  }

  /// Applies tint only when `enabled` is true (used for menu items)
  @ViewBuilder
  func menuTint(_ color: Color, enabled: Bool) -> some View {
    if enabled {
      self.tint(color)
    } else {
      self
    }
  }
}

struct ItemListSearchableModifier: ViewModifier {
  @Binding var text: String
  @Binding var isSearchFocused: Bool
  let prompt: String
  @Binding var selectedScope: ItemListSearchScope

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
      /// New tab bar role handles searches
      content
    } else {
      content
        .searchable(
          text: $text,
          isPresented: $isSearchFocused,
          prompt: prompt
        )
        .searchScopes($selectedScope) {
          ForEach(ItemListSearchScope.allCases) { scope in
            Text(scope.title).tag(scope)
          }
        }
    }
  }
}

extension View {
  func bpSearchable(
    text: Binding<String>,
    isSearchFocused: Binding<Bool>,
    prompt: String,
    selectedScope: Binding<ItemListSearchScope>
  ) -> some View {
    self.modifier(
      ItemListSearchableModifier(
        text: text,
        isSearchFocused: isSearchFocused,
        prompt: prompt,
        selectedScope: selectedScope
      )
    )
  }
}

struct MiniPlayerSafeAreaInsetModifier: ViewModifier {
  @Environment(\.playerState) var playerState
  @Environment(\.miniPlayerBottomInset) private var miniPlayerBottomInset
  @Environment(\.listenTogetherRowIsShown) private var listenTogetherRowIsShown
  @StateObject private var keyboardObserver = KeyboardObserver()

  private var spacerHeight: CGFloat {
    // When keyboard is visible, let iOS handle the safe area adjustment
    guard !keyboardObserver.isKeyboardVisible else { return 0 }

    return playerState.loadedBookRelativePath != nil || listenTogetherRowIsShown ? miniPlayerBottomInset : Spacing.M
  }

  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content
        .safeAreaInset(edge: .bottom) {
          Spacer().frame(height: spacerHeight)
        }
    } else if #available(iOS 26.0, *) {
      /// New accessory view already insets the entire view
      content
        .safeAreaInset(edge: .bottom) {
          Spacer().frame(height: keyboardObserver.isKeyboardVisible ? 0 : Spacing.M)
        }
    } else {
      content
        .safeAreaInset(edge: .bottom) {
          Spacer().frame(height: spacerHeight)
        }
    }
  }
}

extension View {
  func miniPlayerSafeAreaInset() -> some View {
    self.modifier(MiniPlayerSafeAreaInsetModifier())
  }
}

extension View {
  func applyListStyle(
    with theme: ThemeViewModel,
    background: Color
  ) -> some View {
    self
      .contentMargins(.top, Spacing.S1, for: .scrollContent)
      .scrollContentBackground(.hidden)
      .background(background)
      .toolbarColorScheme(theme.useDarkVariant ? .dark : .light, for: .navigationBar)
  }
}

// MARK: - Tab Bar Height Reader

/// Reads the actual UITabBar height from UIKit to avoid hardcoding tab bar dimensions.
/// On iOS 26+ with liquid glass, the tab bar can be taller than the traditional 49pt.
struct TabBarHeightReader: UIViewControllerRepresentable {
  let onHeightChange: (CGFloat) -> Void

  func makeUIViewController(context: Context) -> TabBarHeightReaderController {
    let controller = TabBarHeightReaderController()
    controller.onHeightChange = onHeightChange
    return controller
  }

  func updateUIViewController(_ controller: TabBarHeightReaderController, context: Context) {
    controller.onHeightChange = onHeightChange
  }

  class TabBarHeightReaderController: UIViewController {
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastContentHeight: CGFloat = 0

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      guard let tabBar = tabBarController?.tabBar else { return }
      let windowBottomSafeArea = view.window?.safeAreaInsets.bottom ?? 0
      let contentHeight = tabBar.frame.height - windowBottomSafeArea
      guard contentHeight > 0,
            abs(contentHeight - lastContentHeight) > 1 else { return }
      lastContentHeight = contentHeight
      onHeightChange?(contentHeight)
    }
  }
}

// MARK: - Mini Player Layout

struct MiniPlayerSizePreferenceKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

/// Where the mini player stack (the Listen Together row and the mini player) sits above the bottom chrome,
/// and how far list content must be inset to scroll clear of it.
enum MiniPlayerLayout {
  /// The bottom chrome is the tab bar in compact width, or the editing toolbar in edit mode (it takes the
  /// hidden tab bar's place, and it is at the bottom in regular width too). In regular width, outside
  /// edit mode, the tab bar is at the top, so only minimal spacing is added.
  static func hasBottomChrome(isCompact: Bool, isEditing: Bool) -> Bool {
    isCompact || isEditing
  }

  static func bottomClearance(isCompact: Bool, isEditing: Bool, tabBarContentHeight: CGFloat) -> CGFloat {
    hasBottomChrome(isCompact: isCompact, isEditing: isEditing) ? tabBarContentHeight + 8 : Spacing.S1
  }

  /// The stack's measured height includes its clearance; the bottom chrome already insets the content,
  /// so only the part above the chrome (plus 20 pt) is added.
  static func contentInset(
    stackHeight: CGFloat, isCompact: Bool, isEditing: Bool, tabBarContentHeight: CGFloat
  ) -> CGFloat {
    let chrome = hasBottomChrome(isCompact: isCompact, isEditing: isEditing) ? tabBarContentHeight : 0
    let topPadding: CGFloat = 20
    return stackHeight + topPadding - (stackHeight > chrome ? chrome : 0)
  }
}

struct MiniPlayerModifier<Regular: View, Accessory: View>: ViewModifier {
  @ViewBuilder let regular: () -> Regular
  @ViewBuilder let accessory: () -> Accessory

  @Environment(\.horizontalSizeClass) var hSize
  @Environment(\.tabBarContentHeight) var tabBarContentHeight
  @Environment(\.listState) private var listState
  @State private var miniPlayerBottomInset: CGFloat = 80

  func body(content: Content) -> some View {
    iOSBody(content)
  }

  @ViewBuilder
  private func iOSBody(_ content: Content) -> some View {
    if #available(iOS 26.1, *) {
      defaultBody(content)
    } else if #available(iOS 26.0, *) {
      content
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(content: accessory)
    } else {
      defaultBody(content)
    }
  }

  @ViewBuilder
  private func defaultBody(_ content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        regular()
          .fixedSize(horizontal: false, vertical: true)
          .overlay(
            GeometryReader { geo in
              Color.clear.preference(
                key: MiniPlayerSizePreferenceKey.self,
                value: geo.size
              )
            }
          )
      }
      .onPreferenceChange(MiniPlayerSizePreferenceKey.self) {
        guard $0.height > 0 else { return }
        // The stack's own bottom clearance (MainView) already clears the tab bar or editing toolbar.
        miniPlayerBottomInset = MiniPlayerLayout.contentInset(
          stackHeight: $0.height, isCompact: hSize == .compact, isEditing: listState.isEditing,
          tabBarContentHeight: tabBarContentHeight)
      }
      .environment(\.miniPlayerBottomInset, miniPlayerBottomInset)
  }

}
extension View {
  func miniPlayer<Regular: View, Accessory: View>(
    @ViewBuilder regularContent: @escaping () -> Regular,
    @ViewBuilder accessoryContent: @escaping () -> Accessory
  ) -> some View {
    self.modifier(MiniPlayerModifier<Regular, Accessory>(regular: regularContent, accessory: accessoryContent))
  }
}

extension View {
  func formatSpeed(_ speed: Double) -> String {
    return (speed.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(speed))" : "\(speed)") + "×"
  }
}

extension View {
  /// Applies a context menu only when running as an iOS app on macOS ("Designed for iPad").
  /// Use this to add right-click support on Mac without affecting iOS long-press behavior.
  @ViewBuilder
  func macContextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      self.contextMenu { menuItems() }
    } else {
      self
    }
  }

  /// Selection-based variant for Lists. The menu closure receives the set of item IDs
  /// that were right-clicked, without mutating any state during view evaluation.
  @ViewBuilder
  func macContextMenu<ID: Hashable, MenuItems: View>(
    forSelectionType type: ID.Type,
    @ViewBuilder menu: @escaping (Set<ID>) -> MenuItems
  ) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      self.contextMenu(forSelectionType: type, menu: menu)
    } else {
      self
    }
  }
}

extension View {
  @ViewBuilder
  func liquidGlassBackground() -> some View {
    if #available(iOS 26.0, *) {
      glassEffect()
    } else {
      background(.ultraThinMaterial)
    }
  }
}
