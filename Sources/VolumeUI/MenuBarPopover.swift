import AppKit
import SwiftUI
import VolumeCore

/// Content of the menu bar popover (SPEC 3.2): header, output card, apps and footer.
public struct MenuBarPopover: View {
  private let context: PopoverContext

  /// Creates the popover content.
  public init(context: PopoverContext) {
    self.context = context
  }

  private var store: MixerStore { context.store }

  /// Tallest the app list gets before it scrolls: about six apps (SPEC 3.2), and never so tall
  /// that the popover passes about 70% of the screen. The rest of the popover (header, output
  /// card, section title, footer) takes about 260 pt.
  static func maxListHeight(screenHeight: CGFloat) -> CGFloat {
    max(120, min(400, screenHeight * 0.7 - 260))
  }

  /// The popover.
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      OutputCard(context: context)
      if store.isSafeMode {
        Text("popover.safeMode", bundle: .main)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
      }
      appsSection
      footer
    }
    .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
    .frame(width: 320)
    .background(GlassBackground())
    .focusEffectDisabled()
    .onExitCommand { NSApp.keyWindow?.close() }
  }

  // MARK: Header

  private var header: some View {
    HStack {
      Text("popover.title", bundle: .main)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.primary)
    }
    .padding(.leading, 4)
    .padding(.trailing, 2)
    .frame(height: 24)
  }

  // MARK: Apps

  private var appsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("popover.apps", bundle: .main)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        if !store.showsPermissionNotice {
          Text("popover.playing \(store.playingCount)", bundle: .main)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      .padding(EdgeInsets(top: 2, leading: 4, bottom: 0, trailing: 4))
      if store.showsPermissionNotice {
        PermissionNotice(allow: store.allowAccess)
      } else if store.rows.isEmpty {
        Text("popover.empty", bundle: .main)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
      } else {
        appList
      }
    }
  }

  /// The list takes the height of its rows, so the popover grows with the apps; above the
  /// ceiling it scrolls. A scroll view's ideal height is its content's height, and
  /// `fixedSize` asks for that ideal height, clamped by `maxHeight`: nothing is measured after
  /// the popover appears, so the window never moves on its own when it opens. The scroller
  /// only appears when the list is longer than the ceiling.
  private var appList: some View {
    ScrollView {
      VStack(spacing: 2) {
        ForEach(store.rows) { row in
          AppRowView(row: row, context: context)
        }
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxHeight: maxListHeight)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var maxListHeight: CGFloat {
    Self.maxListHeight(screenHeight: NSScreen.main?.visibleFrame.height ?? 900)
  }

  // MARK: Footer

  private var footerSeparator: some View {
    Rectangle()
      .fill(Palette.separator)
      .frame(height: 1)
      .padding(.horizontal, 8)
  }

  private var footer: some View {
    VStack(spacing: 2) {
      footerSeparator
      OptionsMenuRow(context: context)
      MenuItemRow(
        title: "footer.quit", shortcut: KeyboardShortcut("q", modifiers: .command),
        action: context.quit)
    }
  }
}

/// "No permission" state: replaces the app list (SPEC 3.2). The output card keeps working.
private struct PermissionNotice: View {
  let allow: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Text("permission.message", bundle: .main)
        .font(.system(size: 13))
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button(action: allow) {
        Text("permission.allow", bundle: .main)
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}

/// A menu-like item of the footer. The optional ⌘ shortcut works with the popover open but
/// is not written (SPEC 3.2).
private struct MenuItemRow: View {
  let title: LocalizedStringKey
  let shortcut: KeyboardShortcut?
  let action: @MainActor () -> Void

  @State private var isHovering = false
  @FocusState private var isFocused: Bool

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title, bundle: .main)
          .font(.system(size: 13))
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut)
    .focused($isFocused)
    .rowHighlight(isActive: isHovering || isFocused, cornerRadius: 8)
    .onHover { isHovering = $0 }
  }
}

/// "Opções": a footer item that opens a native menu (SPEC 3.2). The hidden button keeps ⌘,
/// working with the popover open, since a closed menu does not receive shortcuts.
private struct OptionsMenuRow: View {
  let context: PopoverContext

  @State private var isHovering = false
  @FocusState private var isFocused: Bool

  var body: some View {
    Menu {
      Button("footer.sound", action: context.openSoundSettings)
      Button("footer.settings", action: context.showSettings)
      Divider()
      Button("menu.restore", action: context.store.restoreOriginalAudio)
      Button("menu.about", action: context.showAbout)
    } label: {
      HStack {
        Text("footer.options", bundle: .main)
          .font(.system(size: 13))
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .focused($isFocused)
    .rowHighlight(isActive: isHovering || isFocused, cornerRadius: 8)
    .onHover { isHovering = $0 }
    .background {
      Button("", action: context.showSettings)
        .keyboardShortcut(",", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}
