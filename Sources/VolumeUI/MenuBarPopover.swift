import AppKit
import SwiftUI
import VolumeCore

/// Content of the menu bar popover (SPEC 3.2): header, output card, apps and footer.
public struct MenuBarPopover: View {
  private let context: PopoverContext

  @State private var popoverWindow: NSWindow?
  @Environment(\.openSettings) private var openSettings

  /// Creates the popover content.
  public init(context: PopoverContext) {
    self.context = context
  }

  private var store: MixerStore { context.store }

  /// The popover is never taller than about 70% of the screen, and the list shows about five
  /// apps before it scrolls.
  private var maxListHeight: CGFloat {
    let screen = NSScreen.main?.visibleFrame.height ?? 900
    return max(120, min(372, screen * 0.7 - 260))
  }

  /// The popover.
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      OutputCard(context: context)
      if store.isSafeMode {
        Text("popover.safeMode", bundle: .main)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      appsSection
      Divider()
      footer
    }
    .padding(12)
    .frame(width: 320)
    .task {
      store.refreshAudioSystem()
      await context.permission.refresh(onlyIfDenied: true)
    }
    .background(WindowReader { popoverWindow = $0 })
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      note in
      guard let window = popoverWindow, note.object as? NSWindow === window else { return }
      store.refreshAudioSystem()
      Task { await context.permission.refresh(onlyIfDenied: true) }
    }
    .onExitCommand { NSApp.keyWindow?.close() }
  }

  /// The app has no Dock icon, so it must come to the front for the window to be seen.
  private func showSettings() {
    NSApp.activate()
    openSettings()
  }

  // MARK: Header

  private var header: some View {
    HStack {
      Text("popover.title", bundle: .main).font(.headline)
      Spacer()
      Menu {
        Button(action: showSettings) { Text("menu.settings", bundle: .main) }
        Button(action: store.restoreOriginalAudio) { Text("menu.restore", bundle: .main) }
        Button(action: context.showAbout) { Text("menu.about", bundle: .main) }
        Divider()
        Button(action: context.quit) { Text("menu.quit", bundle: .main) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(Text("menu.more", bundle: .main))
    }
  }

  // MARK: Apps

  private var appsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("popover.apps", bundle: .main)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if !context.permission.isDenied {
          Text("popover.playing \(store.playingCount)", bundle: .main)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if context.permission.isDenied {
        PermissionNotice(permission: context.permission)
      } else if store.rows.isEmpty {
        Text("popover.empty", bundle: .main)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
      } else {
        appList
      }
    }
  }

  /// The list has its natural height up to the screen-based ceiling, then it scrolls
  /// (`ViewThatFits` picks the plain list when it fits under the ceiling). Nothing is measured after the popover
  /// appears, so the window never changes size (and position) on its own when it opens.
  private var appList: some View {
    let list = VStack(spacing: 0) {
      ForEach(store.rows) { row in
        AppRowView(row: row, context: context)
      }
    }
    return ViewThatFits(in: .vertical) {
      list
      ScrollView { list }
    }
    .frame(maxHeight: maxListHeight)
    .padding(.horizontal, -12)
  }

  // MARK: Footer

  private var footer: some View {
    VStack(spacing: 0) {
      MenuItemRow(title: "footer.sound", shortcut: nil, action: context.openSoundSettings)
      MenuItemRow(
        title: "footer.settings", shortcut: KeyboardShortcut(",", modifiers: .command),
        action: showSettings)
      MenuItemRow(
        title: "footer.quit", shortcut: KeyboardShortcut("q", modifiers: .command),
        action: context.quit)
    }
  }
}

/// "No permission" state: replaces the app list (SPEC 3.2). The output card keeps working.
private struct PermissionNotice: View {
  let permission: PermissionMonitor

  var body: some View {
    VStack(spacing: 10) {
      Text("permission.message", bundle: .main)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button(action: permission.openPrivacySettings) {
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

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title, bundle: .main)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut)
    .rowHighlight(isActive: isHovering)
    .onHover { isHovering = $0 }
  }
}

/// Reports the window that hosts the popover, so only its key events trigger a permission check.
private struct WindowReader: NSViewRepresentable {
  let onChange: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {}

  final class ReaderView: NSView {
    var onChange: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onChange?(window)
    }
  }
}
