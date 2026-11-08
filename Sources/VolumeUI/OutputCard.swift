import SwiftUI
import VolumeCore

/// Card "Saída principal": default output (changes the system default) and master volume.
struct OutputCard: View {
  let context: PopoverContext

  private var store: MixerStore { context.store }

  var body: some View {
    VStack(spacing: 10) {
      outputMenu
      masterSlider
    }
    .padding(12)
    .cardBackground()
  }

  private var outputMenu: some View {
    Menu {
      ForEach(store.devices) { device in
        Button {
          store.setDefaultOutput(device.uid)
        } label: {
          if device.uid == store.defaultOutputUID {
            Label(device.displayName, systemImage: "checkmark")
          } else {
            Text(verbatim: device.displayName)
          }
        }
      }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: (store.defaultOutput?.kind ?? .other).symbolName)
          .frame(width: 24)
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text("output.label", bundle: .main)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            verbatim: store.defaultOutput?.displayName
              ?? String(localized: "device.unknown", bundle: .main)
          )
          .lineLimit(1)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel(Text("output.label", bundle: .main))
    .accessibilityValue(Text(verbatim: store.defaultOutput?.displayName ?? ""))
  }

  private var masterSlider: some View {
    HStack(spacing: 8) {
      Button {
        store.toggleMasterMute()
      } label: {
        Image(systemName: store.masterMuted ? "speaker.slash.fill" : "speaker.fill")
          .foregroundStyle(store.masterMuted ? Color.red : Color.secondary)
          .frame(width: 20)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text(store.masterMuted ? "a11y.master.unmute" : "a11y.master.mute", bundle: .main))
      Slider(
        value: Binding(get: { store.masterVolume }, set: { store.setMasterVolume($0) }),
        in: 0...1
      )
      .focusable(false)
      .disabled(!store.masterHasVolumeControl)
      .overlay {
        if !store.masterHasVolumeControl {
          Color.clear.contentShape(Rectangle()).help(Text("output.noVolume", bundle: .main))
        }
      }
      .scrollAdjusts(adjust)
      .accessibilityLabel(Text("output.volume", bundle: .main))
      .accessibilityValue(
        Text("a11y.percent \(RowPresentation.percent(store.masterVolume))", bundle: .main)
      )
      .accessibilityAdjustableAction { direction in
        adjust(direction == .increment ? 1 : -1)
      }
      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)
    }
    .volumeKeys(adjust: adjust, space: { store.toggleMasterMute() })
  }

  private func adjust(_ steps: Int) {
    guard store.masterHasVolumeControl else { return }
    store.setMasterVolume(
      RowPresentation.stepped(store.masterVolume, by: context.settings.volumeStep, steps: steps))
  }
}
