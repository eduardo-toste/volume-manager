import Testing
import VolumeCore

@testable import VolumeUI

@Suite("RowPresentation", .timeLimit(.minutes(1)))
struct RowPresentationTests {
  private let airpods = OutputDevice(id: 2, uid: "airpods", name: "AirPods Pro", kind: .bluetooth)
  private let speakers = OutputDevice(id: 1, uid: "speakers", name: "Alto-falantes")

  private func row(
    volume: Double = 1, muted: Bool = false, device: OutputDevice? = nil,
    usesSystemDefault: Bool = true
  ) -> MixerRow {
    MixerRow(
      app: AudioApp(
        id: "com.spotify.client", name: "Spotify", bundleID: "com.spotify.client", pids: [1],
        isPlaying: true),
      state: AppAudioState(volume: volume, muted: muted),
      device: device, usesSystemDefault: usesSystemDefault, savedDeviceMissing: false)
  }

  @Test(arguments: [(0.0, 0), (0.724, 72), (0.725, 73), (1.0, 100), (-1.0, 0), (5.0, 100)])
  func percentIsRoundedAndClamped(volume: Double, expected: Int) {
    #expect(RowPresentation(row: row(volume: volume)).percent == expected)
  }

  @Test func mutedRowKeepsItsPercent() {
    let presentation = RowPresentation(row: row(volume: 0.72, muted: true))
    #expect(presentation.isMuted)
    #expect(presentation.percent == 72)
  }

  @Test func routeNameAppearsOnlyOffTheSystemDefault() {
    #expect(RowPresentation(row: row(device: speakers)).routeName == nil)
    let routed = row(device: airpods, usesSystemDefault: false)
    #expect(RowPresentation(row: routed).routeName == "AirPods Pro")
  }

  @Test func steppingMovesByTheConfiguredStepAndStaysInRange() {
    #expect(RowPresentation.stepped(0.5, by: .five, steps: 1) == 0.55)
    #expect(RowPresentation.stepped(0.5, by: .ten, steps: -2) == 0.3)
    #expect(RowPresentation.stepped(0.5, by: .one, steps: 3) == 0.53)
    #expect(RowPresentation.stepped(0.98, by: .five, steps: 1) == 1)
    #expect(RowPresentation.stepped(0.02, by: .five, steps: -1) == 0)
  }

  @Test func steppingRepeatedlyDoesNotDrift() {
    var volume = 1.0
    for _ in 0..<20 { volume = RowPresentation.stepped(volume, by: .five, steps: -1) }
    #expect(volume == 0)
    for _ in 0..<7 { volume = RowPresentation.stepped(volume, by: .five, steps: 1) }
    #expect(RowPresentation.percent(volume) == 35)
  }

  @Test func everyDeviceKindHasASymbol() {
    for kind in OutputDeviceKind.allCases { #expect(!kind.symbolName.isEmpty) }
  }
}
