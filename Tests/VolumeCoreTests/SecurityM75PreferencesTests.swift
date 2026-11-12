import Foundation
import Testing

@testable import VolumeCore

// Security M7.5: preferences edited by another process with `defaults write`. The values are
// decoded from a property list exactly as cfprefsd stores them (so `-int 1` is an integer, not
// a boolean), and kept in memory: the user's real `com.volumemanager.app` domain is never read
// or written.
@MainActor
@Suite("Security M7.5: hostile preferences as written by defaults", .timeLimit(.minutes(1)))
struct SecurityM75PreferencesTests {
  let clock = FakeClock()

  /// Decodes an XML property list the way the preferences daemon would hand it back.
  private func domain(_ body: String) throws -> [String: Any] {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>\(body)</dict></plist>
      """
    let decoded = try PropertyListSerialization.propertyList(
      from: Data(xml.utf8), options: [], format: nil)
    return try #require(decoded as? [String: Any])
  }

  /// `defaults write … -int 1` / `-float` / `-string` instead of `-bool`: never read as "true".
  @Test func numbersAndStringsAreNotBooleans() throws {
    let values = try domain(
      """
      <key>audioPermissionConfirmed</key><integer>1</integer>
      <key>onboardingCompleted</key><string>YES</string>
      <key>rememberVolumes</key><real>0.0</real>
      <key>volumeStepPercent</key><true/>
      """)
    let settings = SettingsModel(store: InMemoryPreferencesStore(values), clock: clock, build: "1")
    #expect(settings.audioPermissionConfirmed == false)
    #expect(settings.onboardingCompleted == false)
    #expect(settings.rememberVolumes == true)
    #expect(settings.volumeStep == .five)
  }

  /// Data, dates, arrays and deep nesting where records are expected: ignored, nothing muted.
  @Test func wrongContainerTypesAreIgnored() throws {
    for body in [
      "<key>rememberedApps</key><array><string>com.spotify.client</string></array>",
      "<key>rememberedApps</key><data>AAAA</data>",
      "<key>rememberedApps</key><date>2026-01-01T00:00:00Z</date>",
      """
      <key>rememberedApps</key><dict><key>com.spotify.client</key>
      <array><dict><key>volume</key><real>0</real><key>muted</key><true/></dict></array></dict>
      """,
    ] {
      let settings = SettingsModel(
        store: InMemoryPreferencesStore(try domain(body)), clock: clock, build: "1")
      #expect(settings.remembered(for: "com.spotify.client") == nil, "\(body)")
      #expect(settings.rememberedApps.isEmpty, "\(body)")
    }
  }

  /// A record with plist-typed hostile fields: `-int 1` for muted, a huge real, a data UID.
  @Test func hostileRecordFieldsFallBackToTheSafeDefault() throws {
    let values = try domain(
      """
      <key>rememberedApps</key><dict>
        <key>com.a.intmute</key><dict><key>volume</key><integer>0</integer><key>muted</key><integer>1</integer></dict>
        <key>com.a.hugereal</key><dict><key>volume</key><real>1e308</real></dict>
        <key>com.a.datauid</key><dict><key>volume</key><real>0.5</real><key>outputUID</key><data>AAAA</data></dict>
        <key>com.a.newline</key><dict><key>volume</key><real>0.5</real><key>outputUID</key><string>Built-In
      Output</string></dict>
      </dict>
      """)
    let settings = SettingsModel(store: InMemoryPreferencesStore(values), clock: clock, build: "1")
    // `-int 0` is a valid volume (0%), but `-int 1` is not a valid "muted": not muted.
    #expect(settings.remembered(for: "com.a.intmute")?.muted == false)
    #expect(settings.remembered(for: "com.a.hugereal")?.volume == 1)
    #expect(settings.remembered(for: "com.a.datauid")?.outputUID == nil)
    #expect(settings.remembered(for: "com.a.newline")?.outputUID == nil)
  }

  /// Forging the crash counter can only push towards safe mode (the safe side) and stays
  /// bounded; a non-integer counter is treated as zero.
  @Test func forgedCrashCounterIsBounded() throws {
    for (body, safe) in [
      ("<key>safety.earlyCrashes</key><real>1e300</real>", false),
      ("<key>safety.earlyCrashes</key><integer>-9223372036854775807</integer>", false),
      ("<key>safety.earlyCrashes</key><string>99</string>", false),
      ("<key>safety.earlyCrashes</key><true/>", false),
      ("<key>safety.earlyCrashes</key><integer>9223372036854775807</integer>", false),
      ("<key>safety.earlyCrashes</key><integer>999999</integer>", true),
    ] {
      let values = try domain("<key>safety.sessionStarted</key><true/>" + body)
      let store = InMemoryPreferencesStore(values)
      let policy = SafetyPolicy(store: store, clock: clock)
      policy.beginSession()
      #expect(policy.isSafeMode == safe, "\(body)")
      let written = try #require(store.values["safety.earlyCrashes"] as? Int)
      #expect((0...101).contains(written), "\(body)")
    }
  }

  /// `cleanExit -int 1` is not a clean exit: the next launch does not check the permission by
  /// itself (the stale-mark guard of M6 stays on the safe side).
  @Test func integerCleanExitIsNotACleanExit() throws {
    let values = try domain(
      "<key>safety.sessionStarted</key><true/><key>safety.cleanExit</key><integer>1</integer>")
    let policy = SafetyPolicy(store: InMemoryPreferencesStore(values), clock: clock)
    policy.beginSession()
    #expect(policy.previousSessionEndedCleanly == false)
  }
}
