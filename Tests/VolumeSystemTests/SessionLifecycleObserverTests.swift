import AppKit
import Foundation
import Testing

@testable import VolumeSystem

@MainActor
@Suite("SessionLifecycleObserver")
struct SessionLifecycleObserverTests {
  @Test func firesOnPowerOffAndTerminate() async {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    var count = 0
    let observer = SessionLifecycleObserver(workspaceCenter: workspace, appCenter: app) {
      count += 1
    }
    workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    app.post(name: NSApplication.willTerminateNotification, object: nil)
    #expect(count == 2)
    observer.stop()
  }

  @Test func ignoresUnrelatedNotificationsAndStops() {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    var count = 0
    let observer = SessionLifecycleObserver(workspaceCenter: workspace, appCenter: app) {
      count += 1
    }
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(count == 0)
    observer.stop()
    workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    #expect(count == 0)
  }
}
