import Foundation
import Testing
import VolumeAudio
import VolumeCore

@testable import VolumeSystem

/// Security re-check of S75-B2 (M7.5): with `pidStillMatches` gone, the real PID guard is
/// `GroupedProcessIdentity` + `executablePath(forPID:)`. These pin the primitive it relies on
/// (an exited PID stops resolving) and that the real checker rejects gone or hostile PIDs.
/// No audio is played: `/bin/sleep` is not an audio client.
@Suite("Security M7.5: PID revalidation after S75-B2", .timeLimit(.minutes(1)))
struct SecurityM75PIDTests {
  private let provider = WorkspaceAppInfoProvider()

  @Test func exitedProcessStopsResolvingItsPath() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    let pid = child.processIdentifier
    defer {
      if child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
    }
    #expect(provider.executablePath(forPID: pid) == "/bin/sleep")
    child.terminate()
    child.waitUntilExit()
    #expect(provider.executablePath(forPID: pid) == nil)
  }

  @Test(arguments: [Int32(0), -1, Int32.min, Int32.max, 999_999])
  func realIdentityCheckerRejectsGoneOrHostilePIDs(pid: Int32) {
    let catalog = ProcessCatalog(info: provider, responsiblePID: provider.responsiblePID(forPID:))
    let identity = GroupedProcessIdentity(catalog: catalog, info: provider)
    let app = ControlledApp(id: "app:/Applications/Safari.app", bundleID: nil, pids: [pid])
    #expect(!identity.confirm(pid: pid, belongsTo: app))
  }

  @Test func nonAudioProcessIsNeverConfirmed() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer {
      child.terminate()
      child.waitUntilExit()
    }
    let pid = child.processIdentifier
    let catalog = ProcessCatalog(info: provider, responsiblePID: provider.responsiblePID(forPID:))
    let identity = GroupedProcessIdentity(catalog: catalog, info: provider)
    #expect(catalog.processInfo(pid: pid) == nil)
    #expect(
      !identity.confirm(pid: pid, belongsTo: ControlledApp(id: "x", bundleID: nil, pids: [pid])))
  }
}
