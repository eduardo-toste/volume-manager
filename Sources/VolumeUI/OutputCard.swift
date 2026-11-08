import SwiftUI
import VolumeCore

/// Card "Saída principal": default output (changes the system default) and master volume.
struct OutputCard: View {
  let context: PopoverContext

  @FocusState private var isFocused: Bool

  private var store: MixerStore { context.store }

  var body: some View {
    VStack(spacing: 10) {
      outputMenu
      masterSlider
    }
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
          .foregroundStyle(.white)
          .frame(width: 30, height: 30)
          .background(Circle().fill(Color.accentColor))
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
    CapsuleSlider(
      value: Binding(get: { store.masterVolume }, set: { store.setMasterVolume($0) }),
      symbol: masterSymbol, symbolIsAlert: store.masterMuted
    )
    .opacity(store.masterHasVolumeControl ? 1 : 0.4)
    .allowsHitTesting(store.masterHasVolumeControl)
    .scrollAdjusts(adjust)
    .accessibilityLabel(Text("output.volume", bundle: .main))
    .accessibilityValue(
      Text("a11y.percent \(RowPresentation.percent(store.masterVolume))", bundle: .main)
    )
    .accessibilityAdjustableAction { direction in
      adjust(direction == .increment ? 1 : -1)
    }
    .overlay {
      if !store.masterHasVolumeControl {
        Color.clear.contentShape(Rectangle()).help(Text("output.noVolume", bundle: .main))
      }
    }
    .overlay(alignment: .leading) {
      Button {
        store.toggleMasterMute()
      } label: {
        Color.clear.frame(width: 30, height: 24).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text(store.masterMuted ? "a11y.master.unmute" : "a11y.master.mute", bundle: .main))
    }
    .volumeKeys(adjust: adjust, space: { store.toggleMasterMute() })
    .focused($isFocused)
    .rowHighlight(isActive: isFocused)
  }

  private var masterSymbol: String {
    if store.masterMuted || store.masterVolume <= 0 { return "speaker.slash.fill" }
    if store.masterVolume <= 0.33 { return "speaker.wave.1.fill" }
    return store.masterVolume <= 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
  }

  private func adjust(_ steps: Int) {
    guard store.masterHasVolumeControl else { return }
    store.setMasterVolume(
      RowPresentation.stepped(store.masterVolume, by: context.settings.volumeStep, steps: steps))
  }
}
