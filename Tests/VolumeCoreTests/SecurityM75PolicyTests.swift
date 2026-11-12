import Foundation
import Testing

// Security M7.5: the release entitlements and Info.plist, checked by allowlist instead of a
// list of forbidden keys (SPEC 12.9.2, CLAUDE.md rules 5 and 6). `security-check.sh` only knows
// six forbidden keys; it accepts, for example, `cs.disable-executable-page-protection` (a
// Hardened Runtime exception) and `device.audio-input` (microphone). The app needs none.
@Suite("Security M7.5: entitlements and Info.plist by allowlist")
struct SecurityM75PolicyTests {
  private func plist(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: RepositoryFiles.root.appendingPathComponent(relativePath))
    let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(decoded as? [String: Any])
  }

  /// No entitlement at all: no runtime exception, no resource access (microphone, camera,
  /// Apple Events, …). The audio capture permission needs no entitlement.
  @Test func releaseEntitlementsAreEmpty() throws {
    let entitlements = try plist("Resources/VolumeManager.entitlements")
    #expect(entitlements.isEmpty, "unexpected entitlements: \(entitlements.keys.sorted())")
  }

  /// Nothing that lets other processes hand the app input: URL schemes, document types,
  /// Services, AppleScript, Apple Events usage. Only the audio capture usage text.
  @Test func infoPlistOpensNoInputChannel() throws {
    let info = try plist("Resources/Info.plist")
    for key in [
      "CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations",
      "UTImportedTypeDeclarations", "NSServices", "NSAppleScriptEnabled",
      "OSAScriptingDefinition", "NSAppleEventsUsageDescription", "NSUserActivityTypes",
      "NSExtension", "LSEnvironment", "NSAppTransportSecurity",
    ] {
      #expect(info[key] == nil, "\(key)")
    }
    let usage = info.keys.filter { $0.hasSuffix("UsageDescription") }
    #expect(usage == ["NSAudioCaptureUsageDescription"])
  }
}
