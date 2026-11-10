import SwiftUI
import VolumeCore

/// Card "Saída principal": default output (changes the system default) and master volume.
struct OutputCard: View {
  let context: PopoverContext

  @FocusState private var isFocused: Bool

  private var store: MixerStore { context.store }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      outputMenu
      volumeRow
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
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
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(Circle().fill(Color.accentColor))
        VStack(alignment: .leading, spacing: 0) {
          Text("output.label", bundle: .main)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
          Text(
            verbatim: store.defaultOutput?.displayName
              ?? String(localized: "device.unknown", bundle: .main)
          )
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .frame(height: 28)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .focusEffectDisabled()
    .accessibilityLabel(Text("output.label", bundle: .main))
    .accessibilityValue(Text(verbatim: store.defaultOutput?.displayName ?? ""))
  }

  /// Speaker at each end of the slider; the small one mutes and unmutes the output (SPEC 3.2).
  private var volumeRow: some View {
    HStack(spacing: 10) {
      Button {
        store.toggleMasterMute()
      } label: {
        speaker(store.masterMuted ? "speaker.slash.fill" : "speaker.fill")
          .foregroundStyle(store.masterMuted ? Color(nsColor: .systemRed) : .secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text(store.masterMuted ? "a11y.master.unmute" : "a11y.master.mute", bundle: .main))
      masterSlider
      speaker("speaker.wave.2.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .frame(height: 19)
  }

  private var masterSlider: some View {
    VolumeSlider(
      value: Binding(get: { store.masterVolume }, set: { store.setMasterVolume($0) }),
      isDimmed: store.masterMuted
    )
    .allowsHitTesting(store.masterHasVolumeControl)
    .opacity(store.masterHasVolumeControl ? 1 : 0.4)
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
    .volumeKeys(adjust: adjust, space: { store.toggleMasterMute() })
    .focused($isFocused)
    .rowHighlight(isActive: isFocused, cornerRadius: 6)
  }

  private func speaker(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 12))
      .frame(width: 17, height: 14)
  }

  private func adjust(_ steps: Int) {
    guard store.masterHasVolumeControl else { return }
    store.setMasterVolume(
      RowPresentation.stepped(store.masterVolume, by: context.settings.volumeStep, steps: steps))
  }
}
