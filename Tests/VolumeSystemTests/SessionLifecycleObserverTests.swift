import AppKit
import Foundation
import Testing

@testable import VolumeSystem

@MainActor
@Suite("SessionLifecycleObserver", .timeLimit(.minutes(1)))
struct SessionLifecycleObserverTests {
  private final class Counts {
    var exits = 0
    var resumes = 0
  }

  private func make(
    _ workspace: NotificationCenter, _ app: NotificationCenter, _ counts: Counts
  ) -> SessionLifecycleObserver {
    SessionLifecycleObserver(
      workspaceCenter: workspace, appCenter: app,
      onCleanExit: { counts.exits += 1 }, onResume: { counts.resumes += 1 })
  }

  @Test func firesOnPowerOffAndTerminate() async {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let counts = Counts()
    let observer = make(workspace, app, counts)
    workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    app.post(name: NSApplication.willTerminateNotification, object: nil)
    #expect(counts.exits == 2)
    #expect(counts.resumes == 0)
    observer.stop()
  }

  /// M6: waking up and coming back to this user's session (fast user switching) resume.
  @Test func wakeAndSessionBecomingActiveResume() {
    let workspace = NotificationCenter()
    let counts = Counts()
    let observer = make(workspace, NotificationCenter(), counts)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    #expect(counts.resumes == 2)
    #expect(counts.exits == 0, "sleeping or switching away is not a clean exit")
    workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(counts.resumes == 2)
    observer.stop()
  }

  @Test func ignoresUnrelatedNotificationsAndStops() {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let counts = Counts()
    let observer = make(workspace, app, counts)
    workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    #expect(counts.exits == 0 && counts.resumes == 0)
    observer.stop()
    workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(counts.exits == 0 && counts.resumes == 0)
  }
}
