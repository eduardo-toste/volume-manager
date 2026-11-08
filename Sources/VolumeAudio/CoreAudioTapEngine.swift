import CoreAudio
import Dispatch
import Foundation
import VolumeCore

/// The real `TapEngine`.
final class CoreAudioTapEngine: TapEngine {
  private let catalog: ProcessCatalog
  private let identity: any ProcessIdentityChecking
  private let hub = EventHub<EnvironmentChange>()
  private let queue = DispatchQueue(label: "com.volumemanager.audio.taps")
  private let restartListener: PropertyListener?

  init(catalog: ProcessCatalog, identity: any ProcessIdentityChecking) {
    self.catalog = catalog
    self.identity = identity
    let hub = hub
    restartListener = try? PropertyListener(
      object: AudioProperty.system,
      addresses: [AudioProperty.address(kAudioHardwarePropertyServiceRestarted)],
      queue: queue, handler: { hub.yield(.serviceRestarted) })
  }

  func deviceSignature(uid: String) -> DeviceSignature? {
    DeviceCatalog.signature(forUID: uid)
  }

  /// PID, bundle ID and path are checked again right before the tap exists (SPEC 12.9.4). The
  /// PID is converted to its object once; the object must still report that PID after the
  /// check, and from here on only the object is used.
  func confirmedProcesses(for app: ControlledApp) -> [ConfirmedProcess] {
    app.pids.compactMap { pid in
      guard let object = catalog.objectID(forPID: pid),
        identity.confirm(pid: pid, belongsTo: app),
        catalog.pid(of: object) == pid
      else { return nil }
      return ConfirmedProcess(pid: pid, objectID: object)
    }
  }

  func isRunningOutput(pids: [Int32]) -> Bool { catalog.isRunningOutput(pids: pids) }

  func makeSession(_ request: TapRequest, isCancelled: @Sendable () -> Bool) throws(TapError)
    -> any TapHandle
  {
    guard !request.processes.isEmpty else { throw .processGone }
    let hub = hub
    return try CoreAudioTapSession.start(
      request, queue: queue, notify: { hub.yield($0) },
      isCancelled: isCancelled)
  }

  func environmentChanges() -> AsyncStream<EnvironmentChange> { hub.makeStream() }
}
