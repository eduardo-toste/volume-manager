import CoreAudio
import Darwin
import Foundation
import VolumeCore

/// Reads the audio processes Core Audio knows about (SPEC 4.1). All text is untrusted.
public struct ProcessCatalog: Sendable {
  private let info: (any AppInfoProvider)?
  private let responsiblePID: @Sendable (Int32) -> Int32?

  /// Creates a catalog. `info` supplies executable paths; `responsiblePID` supplies the
  /// "responsible process" (for example from `WorkspaceAppInfoProvider`). Both are optional.
  public init(
    info: (any AppInfoProvider)? = nil,
    responsiblePID: @escaping @Sendable (Int32) -> Int32? = { _ in nil }
  ) {
    self.info = info
    self.responsiblePID = responsiblePID
  }

  /// Object IDs of every audio process.
  func objectIDs() -> [AudioObjectID] {
    let address = AudioProperty.address(kAudioHardwarePropertyProcessObjectList)
    return (try? AudioProperty.array(AudioProperty.system, address, initial: AudioObjectID(0)))
      ?? []
  }

  /// Every audio process, with its path and responsible process when available.
  public func processes() -> [AudioProcessInfo] {
    objectIDs().compactMap { describe($0) }
  }

  /// The audio process with this PID, read fresh, or `nil` if Core Audio no longer lists it.
  public func processInfo(pid: Int32) -> AudioProcessInfo? {
    guard let object = objectID(forPID: pid) else { return nil }
    return describe(object)
  }

  /// The Core Audio object of the process with this PID, if it is an audio client.
  func objectID(forPID pid: Int32) -> AudioObjectID? {
    guard pid > 0 else { return nil }
    var qualifier = pid_t(pid)
    var address = AudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var object = AudioProperty.unknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioProperty.system, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size,
      &object)
    guard status == noErr, object != AudioProperty.unknown else { return nil }
    return object
  }

  /// True if any of the processes reports output right now.
  func isRunningOutput(pids: [Int32]) -> Bool {
    pids.contains { pid in
      guard let object = objectID(forPID: pid) else { return false }
      return runningOutput(object)
    }
  }

  /// Audio processes (other than `excluding`) that are producing output now.
  func playingObjectIDs(excluding pid: Int32) -> [AudioObjectID] {
    objectIDs().filter { object in
      guard let own = self.pid(of: object), own != pid else { return false }
      return runningOutput(object)
    }
  }

  func pid(of object: AudioObjectID) -> pid_t? {
    try? AudioProperty.get(
      object, AudioProperty.address(kAudioProcessPropertyPID), initial: pid_t(0))
  }

  func runningOutput(_ object: AudioObjectID) -> Bool {
    let address = AudioProperty.address(kAudioProcessPropertyIsRunningOutput)
    return ((try? AudioProperty.get(object, address, initial: UInt32(0))) ?? 0) != 0
  }

  /// `IsRunningInput`: only a flag of the process (in a call), never input audio (SPEC 3.2).
  func runningInput(_ object: AudioObjectID) -> Bool {
    let address = AudioProperty.address(kAudioProcessPropertyIsRunningInput)
    return ((try? AudioProperty.get(object, address, initial: UInt32(0))) ?? 0) != 0
  }

  private func describe(_ object: AudioObjectID) -> AudioProcessInfo? {
    guard
      let pid: pid_t = try? AudioProperty.get(
        object, AudioProperty.address(kAudioProcessPropertyPID), initial: pid_t(0)),
      pid > 0
    else { return nil }
    let bundle = try? AudioProperty.string(
      object, AudioProperty.address(kAudioProcessPropertyBundleID))
    let responsible = responsiblePID(pid)
    return AudioProcessInfo(
      pid: pid,
      bundleID: bundle.flatMap { $0.isEmpty ? nil : $0 },
      executablePath: info?.executablePath(forPID: pid),
      responsiblePID: responsible,
      isRunningOutput: runningOutput(object),
      isRunningInput: runningInput(object))
  }
}

/// Confirms that a PID still belongs to the app it was grouped under (SPEC 12.9.4: PID,
/// bundle ID and path must still match before a tap is created).
public protocol ProcessIdentityChecking: Sendable {
  /// True if `pid` is still an audio process that belongs to `app`.
  func confirm(pid: Int32, belongsTo app: ControlledApp) -> Bool
}

/// Re-runs the domain's grouping on the freshly read process and compares the app key.
public struct GroupedProcessIdentity: ProcessIdentityChecking {
  private let catalog: ProcessCatalog
  private let info: any AppInfoProvider

  /// Creates the checker.
  public init(catalog: ProcessCatalog, info: any AppInfoProvider) {
    self.catalog = catalog
    self.info = info
  }

  /// See `ProcessIdentityChecking`.
  public func confirm(pid: Int32, belongsTo app: ControlledApp) -> Bool {
    guard let process = catalog.processInfo(pid: pid) else { return false }
    let groups = ProcessGrouping.group([process], info: info)
    return groups.count == 1 && groups.first?.id == app.id
  }
}
