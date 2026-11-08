import SwiftUI
import VolumeCore

/// One app of the mixer: icon, name, value, optional output label, volume slider and mute
/// button; expanded, the list of outputs for this app ("SAÍDA DESTE APP").
struct AppRowView: View {
  let row: MixerRow
  let context: PopoverContext

  @State private var isHovering = false
  @FocusState private var isFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var store: MixerStore { context.store }
  private var presentation: RowPresentation { RowPresentation(row: row) }
  private var isExpanded: Bool { store.expandedAppID == row.id }
  private var failed: Bool { store.failedAppIDs.contains(row.id) }
  /// A failed app plays at its original volume, so the requested state is not shown as applied.
  private var showsMuted: Bool { row.state.muted && !failed }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .rowHighlight(isActive: isHovering || isExpanded || isFocused)
      if isExpanded {
        OutputChoices(row: row, store: store)
          .padding(EdgeInsets(top: 8, leading: 48, bottom: 4, trailing: 8))
          .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .padding(.bottom, isExpanded ? 6 : 0)
    .background(
      isExpanded ? Palette.highlight : Color.clear,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .default, value: isExpanded)
    .volumeKeys(adjust: adjust, space: { store.toggleMute(row.id) })
    .focused($isFocused)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(presentation.accessibilityLabel(failed: failed))
  }

  // MARK: Parts

  private var header: some View {
    HStack(spacing: 10) {
      expandButton { icon }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          expandButton {
            Text(verbatim: presentation.appName)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(showsMuted ? .secondary : .primary)
              .lineLimit(1)
          }
          .accessibilityHint(Text("a11y.row.expand", bundle: .main))
          Spacer(minLength: 4)
          valueText
        }
        if failed {
          Text("row.failed", bundle: .main)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
            .lineLimit(2)
        } else if let route = presentation.routeName {
          expandButton { routeLabel(route) }
            .accessibilityHidden(true)
        }
        slider
      }
      muteButton
    }
  }

  private var icon: some View {
    Group {
      if let bundleID = row.app.bundleID, let image = context.icon(bundleID) {
        Image(nsImage: image).resizable().interpolation(.high)
      } else {
        Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
      }
    }
    .frame(width: 30, height: 30)
  }

  /// "🔈 AirPods Pro ⌄" in the accent color, under the name (SPEC 3.2).
  private func routeLabel(_ route: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "speaker.fill").font(.system(size: 11))
      Text(verbatim: route).font(.system(size: 11, weight: .medium)).lineLimit(1)
      Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
    }
    .foregroundStyle(Color.accentColor)
  }

  private var valueText: some View {
    Group {
      if failed {
        EmptyView()
      } else if presentation.isMuted {
        Text("row.muted", bundle: .main)
      } else {
        Text(verbatim: "\(presentation.percent)%")
      }
    }
    .font(.system(size: 11).monospacedDigit())
    .foregroundStyle(.secondary)
    .accessibilityHidden(true)
  }

  private var muteButton: some View {
    Button {
      store.toggleMute(row.id)
    } label: {
      Image(systemName: showsMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
        .font(.system(size: 12))
        .foregroundStyle(showsMuted ? Color(nsColor: .systemRed) : .primary)
        .frame(width: 26, height: 26)
        .background(Circle().fill(showsMuted ? Palette.mutedButtonFill : Palette.buttonFill))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      Text(showsMuted ? "a11y.row.unmute" : "a11y.row.mute", bundle: .main))
  }

  private var slider: some View {
    VolumeSlider(
      value: Binding(get: { row.state.volume }, set: { store.setVolume($0, for: row.id) }),
      isDimmed: showsMuted
    )
    .scrollAdjusts(adjust)
    .accessibilityLabel(Text(verbatim: presentation.appName))
    .accessibilityValue(Text("a11y.percent \(presentation.percent)", bundle: .main))
    .accessibilityAdjustableAction { direction in
      adjust(direction == .increment ? 1 : -1)
    }
  }

  /// The icon, the name and the output label expand the row (SPEC 3.2).
  private func expandButton(@ViewBuilder _ label: () -> some View) -> some View {
    Button(action: toggleExpanded) { label().contentShape(Rectangle()) }
      .buttonStyle(.plain)
  }

  // MARK: Intents

  private func toggleExpanded() {
    store.toggleExpanded(row.id)
  }

  private func adjust(_ steps: Int) {
    let next = RowPresentation.stepped(
      row.state.volume, by: context.settings.volumeStep, steps: steps)
    store.setVolume(next, for: row.id)
  }
}

/// "SAÍDA DESTE APP": the system default first, then every connected output; the current one
/// has a check mark.
private struct OutputChoices: View {
  let row: MixerRow
  let store: MixerStore

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("row.outputs", bundle: .main)
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
      OutputChoice(
        title: String(
          format: String(localized: "row.defaultOutput", bundle: .main),
          store.defaultOutput?.displayName ?? String(localized: "device.unknown", bundle: .main)),
        isCurrent: row.usesSystemDefault
      ) { store.route(row.id, to: nil) }
      ForEach(store.devices) { device in
        OutputChoice(
          title: device.displayName,
          isCurrent: !row.usesSystemDefault && row.device?.uid == device.uid
        ) { store.route(row.id, to: device.uid) }
      }
    }
  }
}

/// One output of the list: check mark column, then the name; the current one is highlighted.
private struct OutputChoice: View {
  let title: String
  let isCurrent: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 12)
          .opacity(isCurrent ? 1 : 0)
        Text(verbatim: title)
          .font(.system(size: 13, weight: isCurrent ? .medium : .regular))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .rowHighlight(isActive: isCurrent || isHovering, cornerRadius: 8)
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}
