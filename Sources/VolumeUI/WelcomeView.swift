import AppKit
import SwiftUI
import VolumeCore

/// The welcome window (SPEC 3.4), 480 x 600: icon, title, three highlights, a group with the
/// login toggle and the permission, and the "Começar" button.
struct WelcomeView: View {
  let model: WelcomeModel
  /// Runs after `model.start()`: closes the window and shows the popover.
  let onStart: @MainActor () -> Void

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 22) {
      AppIconView(size: 96)
      VStack(spacing: 4) {
        Text("welcome.title", bundle: .main)
          .font(.system(size: 22, weight: .bold))
        Text("welcome.subtitle", bundle: .main)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      VStack(alignment: .leading, spacing: 14) {
        Feature(
          symbol: "music.note", title: "welcome.feature.volume", text: "welcome.feature.volume.text"
        )
        Feature(
          symbol: "arrow.left.arrow.right", title: "welcome.feature.output",
          text: "welcome.feature.output.text")
        Feature(
          symbol: "circle.lefthalf.filled", title: "welcome.feature.system",
          text: "welcome.feature.system.text")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      group(model)
      Button {
        model.start()
        onStart()
      } label: {
        Text("welcome.start", bundle: .main)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 32)
    .padding(.top, 40)
    .padding(.bottom, 28)
    .frame(width: 480, height: 600)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in model.refreshAccess()
    }
  }

  private func group(_ model: WelcomeModel) -> some View {
    @Bindable var model = model
    return VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("settings.login", bundle: .main)
          Text("welcome.login.subtitle", bundle: .main)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle(isOn: $model.launchAtLogin) { Text("settings.login", bundle: .main) }
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .padding(.vertical, 10)
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("welcome.access", bundle: .main)
          Text(accessNote(model.access), bundle: .main)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        accessControl(model)
      }
      .padding(.vertical, 10)
    }
    .padding(.horizontal, 12)
    .background(
      .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  @ViewBuilder
  private func accessControl(_ model: WelcomeModel) -> some View {
    if model.access == .allowed {
      Label {
        Text("welcome.allowed", bundle: .main)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
    } else {
      Button {
        Task { await model.allow() }
      } label: {
        Text(model.access == .denied ? "welcome.openPrivacy" : "permission.allow", bundle: .main)
      }
      .disabled(model.isAsking)
    }
  }

  private func accessNote(_ access: WelcomeModel.Access) -> LocalizedStringKey {
    switch access {
    case .notAsked, .allowed: "welcome.access.subtitle"
    case .inconclusive: "welcome.access.inconclusive"
    case .denied: "welcome.access.denied"
    }
  }
}

private struct Feature: View {
  let symbol: String
  let title: LocalizedStringKey
  let text: LocalizedStringKey

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title, bundle: .main).font(.system(size: 13, weight: .semibold))
        Text(text, bundle: .main).font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
  }
}
