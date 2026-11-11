import AppKit
import SwiftUI
import VolumeCore

/// A section of the settings window (SPEC 3.3).
enum SettingsPane: CaseIterable, Hashable {
  case general, apps, devices, about

  var title: LocalizedStringKey {
    switch self {
    case .general: "settings.pane.general"
    case .apps: "settings.pane.apps"
    case .devices: "settings.pane.devices"
    case .about: "settings.pane.about"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .apps: "square.grid.2x2"
    case .devices: "hifispeaker"
    case .about: "info.circle"
    }
  }
}

/// The settings window: a sidebar and, next to it, the grouped form of the chosen section.
struct SettingsView: View {
  let context: SettingsContext

  @State private var selection: SettingsPane

  init(context: SettingsContext, pane: SettingsPane = .general) {
    self.context = context
    _selection = State(initialValue: pane)
  }

  var body: some View {
    NavigationSplitView {
      List(SettingsPane.allCases, id: \.self, selection: $selection) { pane in
        Label {
          Text(pane.title, bundle: .main)
        } icon: {
          Image(systemName: pane.symbol)
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(220)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      detail
        .navigationTitle(Text(selection.title, bundle: .main))
    }
    .frame(width: 780, height: 560)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in context.loginItem.refresh()
    }
    .onAppear { context.loginItem.refresh() }
  }

  @ViewBuilder
  private var detail: some View {
    switch selection {
    case .general: GeneralPane(context: context)
    case .apps: AppsPane(context: context)
    case .devices: DevicesPane(context: context)
    case .about: AboutPane(context: context)
    }
  }
}

/// A form row with a title and a secondary line below it.
private struct TitledLabel: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title, bundle: .main)
      if let subtitle {
        Text(subtitle, bundle: .main)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct GeneralPane: View {
  let context: SettingsContext

  var body: some View {
    @Bindable var settings = context.settings
    let loginItem = context.loginItem
    Form {
      Section {
        Toggle(
          isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) })
        ) {
          TitledLabel(title: "settings.login", subtitle: "settings.login.subtitle")
        }
        if loginItem.needsApproval {
          HStack {
            Text("settings.login.approval", bundle: .main)
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            Button(action: loginItem.openSettings) {
              Text("settings.login.open", bundle: .main)
            }
          }
        } else if loginItem.lastChangeFailed {
          Text("settings.login.failed", bundle: .main)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Section {
        Toggle(isOn: $settings.rememberVolumes) {
          TitledLabel(title: "settings.remember", subtitle: "settings.remember.subtitle")
        }
        Picker(selection: $settings.volumeStep) {
          ForEach(VolumeStep.allCases, id: \.self) { step in
            Text(verbatim: "\(step.rawValue)%").tag(step)
          }
        } label: {
          Text("settings.step", bundle: .main)
        }
      } header: {
        Text("settings.volume", bundle: .main)
      }
    }
    .formStyle(.grouped)
  }
}

private struct AppsPane: View {
  let context: SettingsContext

  var body: some View {
    let rows = RememberedRow.rows(
      settings: context.settings, devices: context.store.devices, name: context.appName)
    Form {
      if rows.isEmpty {
        Section {
          Text("settings.apps.empty", bundle: .main)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
        }
      } else {
        Section {
          ForEach(rows) { row in
            HStack(spacing: 10) {
              AppIcon(image: context.icon(row.bundleID))
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name).lineLimit(1)
                Text(verbatim: detail(row))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Button {
                context.settings.forget(row.bundleID)
              } label: {
                Text("settings.apps.forget", bundle: .main)
              }
            }
          }
        }
        Section {
          Button(role: .destructive, action: context.settings.forgetAll) {
            Text("settings.apps.forgetAll", bundle: .main)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private func detail(_ row: RememberedRow) -> String {
    let volume =
      row.muted
      ? String(localized: "row.muted", bundle: .main) : "\(row.percent)%"
    let output =
      row.outputName
      ?? (row.outputMissing
        ? String(localized: "settings.apps.outputMissing", bundle: .main)
        : String(localized: "settings.apps.defaultOutput", bundle: .main))
    return "\(volume) · \(output)"
  }
}

/// A 28 pt app icon, or an empty rounded square when the app is not installed.
private struct AppIcon: View {
  let image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable()
      } else {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary)
      }
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
  }
}

private struct DevicesPane: View {
  let context: SettingsContext

  private var store: MixerStore { context.store }

  var body: some View {
    Form {
      Section {
        if store.devices.isEmpty {
          Text("settings.devices.empty", bundle: .main)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
        }
        ForEach(store.devices) { device in
          let isDefault = device.uid == store.defaultOutputUID
          HStack(spacing: 10) {
            Image(systemName: device.kind.symbolName)
              .frame(width: 28)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: device.displayName).lineLimit(1)
              Text(device.kind.label, bundle: .main)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isDefault {
              Label {
                Text("settings.devices.default", bundle: .main)
              } icon: {
                Image(systemName: "checkmark")
              }
              .foregroundStyle(.secondary)
            } else {
              Button {
                store.setDefaultOutput(device.uid)
              } label: {
                Text("settings.devices.makeDefault", bundle: .main)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct AboutPane: View {
  let context: SettingsContext

  var body: some View {
    VStack(spacing: 8) {
      AppIconView(size: 96)
      Text(verbatim: AppIdentity.displayName)
        .font(.title2.weight(.semibold))
      Text("settings.about.version \(context.version) \(context.build)", bundle: .main)
        .foregroundStyle(.secondary)
      Button(action: context.openRepository) {
        Text("settings.about.repository", bundle: .main)
      }
      .buttonStyle(.link)
      .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension OutputDeviceKind {
  /// Name of the kind of device, as shown in the list of devices.
  var label: LocalizedStringKey {
    switch self {
    case .builtIn: "device.kind.builtIn"
    case .usb: "device.kind.usb"
    case .bluetooth: "device.kind.bluetooth"
    case .display: "device.kind.display"
    case .airPlay: "device.kind.airPlay"
    case .virtual: "device.kind.virtual"
    case .other: "device.kind.other"
    }
  }
}

/// The app's own icon (the one of the Dock and the Finder), at `size` points.
struct AppIconView: View {
  let size: CGFloat

  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
