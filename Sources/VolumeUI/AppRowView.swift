import SwiftUI
import VolumeCore

/// One app of the mixer: icon, name, value, volume slider, mute, and the optional list of
/// outputs for this app.
struct AppRowView: View {
  let row: MixerRow
  let context: PopoverContext

  @State private var isHovering = false
  @FocusState private var isFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Icon width plus spacing: sliders and output choices line up with the name.
  private static let textColumn: CGFloat = 40

  private var store: MixerStore { context.store }
  private var presentation: RowPresentation { RowPresentation(row: row) }
  private var isExpanded: Bool { store.expandedAppID == row.id }
  private var failed: Bool { store.failedAppIDs.contains(row.id) }
  /// A failed app plays at its original volume, so the requested state is not shown as applied.
  private var showsMuted: Bool { row.state.muted && !failed }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button(action: toggleExpanded) {
          HStack(spacing: 10) {
            icon
            titles
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("a11y.row.expand", bundle: .main))
        Spacer(minLength: 4)
        valueText
        muteButton
      }
      slider.padding(.leading, Self.textColumn)
      if isExpanded {
        OutputChoices(row: row, store: store)
          .padding(.leading, Self.textColumn)
          .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .rowHighlight(isActive: isHovering || isExpanded || isFocused)
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .default, value: isExpanded)
    .volumeKeys(adjust: adjust, space: { store.toggleMute(row.id) })
    .focused($isFocused)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(presentation.accessibilityLabel(failed: failed))
  }

  // MARK: Parts

  private var icon: some View {
    Group {
      if let bundleID = row.app.bundleID, let image = context.icon(bundleID) {
        Image(nsImage: image).resizable().interpolation(.high)
      } else {
        Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
      }
    }
    .frame(width: 30, height: 30)
    .accessibilityHidden(true)
  }

  private var titles: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: presentation.appName)
        .lineLimit(1)
        .foregroundStyle(showsMuted ? .secondary : .primary)
      if failed {
        Text("row.failed", bundle: .main)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      } else if let route = presentation.routeName {
        HStack(spacing: 3) {
          Image(systemName: "speaker.wave.2.fill")
          Text(verbatim: route).lineLimit(1)
          Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
      }
    }
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
    .font(.callout.monospacedDigit())
    .foregroundStyle(.secondary)
    .accessibilityHidden(true)
  }

  private var muteButton: some View {
    Button {
      store.toggleMute(row.id)
    } label: {
      Image(systemName: showsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .foregroundStyle(showsMuted ? Color.red : Color.secondary)
        .frame(width: 28, height: 28)
        .background(
          Circle().fill(showsMuted ? Color.red.opacity(0.15) : Color.primary.opacity(0.06)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      Text(showsMuted ? "a11y.row.unmute" : "a11y.row.mute", bundle: .main))
  }

  private var slider: some View {
    CapsuleSlider(
      value: Binding(get: { row.state.volume }, set: { store.setVolume($0, for: row.id) }),
      symbol: showsMuted ? "speaker.slash.fill" : "speaker.fill", height: 18
    )
    .opacity(showsMuted ? 0.65 : 1)
    .scrollAdjusts(adjust)
    .accessibilityLabel(Text(verbatim: presentation.appName))
    .accessibilityValue(Text("a11y.percent \(presentation.percent)", bundle: .main))
    .accessibilityAdjustableAction { direction in
      adjust(direction == .increment ? 1 : -1)
    }
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
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
      choice(
        title: String(
          format: String(localized: "row.defaultOutput", bundle: .main),
          store.defaultOutput?.displayName ?? String(localized: "device.unknown", bundle: .main)),
        isCurrent: row.usesSystemDefault
      ) { store.route(row.id, to: nil) }
      ForEach(store.devices) { device in
        choice(
          title: device.displayName,
          isCurrent: !row.usesSystemDefault && row.device?.uid == device.uid
        ) { store.route(row.id, to: device.uid) }
      }
    }
  }

  private func choice(title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(verbatim: title).lineLimit(1)
        Spacer()
        if isCurrent { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
      }
      .font(.callout)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}
