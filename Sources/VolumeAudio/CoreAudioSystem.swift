import CoreAudio
import Dispatch
import Foundation
import VolumeCore

/// The real `AudioSystem`: output devices, default output, overall volume and mute, and the
/// list of audio processes, all kept current by Core Audio listeners (no polling).
///
/// Listener callbacks only post a trigger. A task owned by this actor re-reads the state,
/// compares it with what was last published and emits only real changes, each carrying the
/// complete new value (SPEC 12.1). The mutable state lives in the actor (SPEC 12.2).
public actor CoreAudioSystem: AudioSystem {
  private enum Trigger: Sendable { case changed, serviceRestarted }

  private let catalog: ProcessCatalog
  private let hub = EventHub<AudioSystemEvent>()
  private let triggers = EventHub<Trigger>()
  private let queue = DispatchQueue(label: "com.volumemanager.audio.listeners")

  private var started = false
  private var monitor: Task<Void, Never>?
  private var systemListener: PropertyListener?
  private var restartListener: PropertyListener?
  private var processListeners: [AudioObjectID: PropertyListener] = [:]
  private var masterListener: PropertyListener?
  private var masterDeviceID = AudioProperty.unknown
  private var last: AudioSystemSnapshot?

  /// Creates the system view. `catalog` decides how much is known about each process.
  public init(catalog: ProcessCatalog = ProcessCatalog()) {
    self.catalog = catalog
  }

  deinit {
    monitor?.cancel()
    hub.finishAll()
    triggers.finishAll()
  }

  // MARK: AudioSystem

  /// A stream of changes; starts the listeners on first use.
  public nonisolated func events() -> AsyncStream<AudioSystemEvent> {
    let stream = hub.makeStream()
    Task { await self.startIfNeeded() }
    return stream
  }

  /// Reads everything now and records it as the baseline for later events.
  public func currentState() async -> AudioSystemSnapshot {
    startIfNeeded()
    let snapshot = readSnapshot()
    last = snapshot
    return snapshot
  }

  /// Re-reads everything once and emits what changed (the popover just opened).
  public func refresh() async {
    guard started else { return }
    handle(.changed)
  }

  /// Sets the volume of the default output device.
  public func setMasterVolume(_ volume: Double) async {
    guard let id = DeviceCatalog.defaultOutputID() else { return }
    do {
      try DeviceCatalog.setMasterVolume(id, volume: volume)
    } catch {
      AudioLog.logger.error("set master volume failed: \(error.description, privacy: .public)")
    }
  }

  /// Mutes or unmutes the default output device.
  public func setMasterMuted(_ muted: Bool) async {
    guard let id = DeviceCatalog.defaultOutputID() else { return }
    do {
      try DeviceCatalog.setMasterMuted(id, muted: muted)
    } catch {
      AudioLog.logger.error("set master mute failed: \(error.description, privacy: .public)")
    }
  }

  /// Makes the device with this UID the system default output.
  public func setDefaultOutput(uid: String) async {
    guard let id = DeviceCatalog.deviceID(forUID: uid) else { return }
    do {
      try DeviceCatalog.setDefaultOutput(id)
    } catch {
      AudioLog.logger.error("set default output failed: \(error.description, privacy: .public)")
    }
  }

  // MARK: Monitoring

  private func startIfNeeded() {
    guard !started else { return }
    started = true
    let stream = triggers.makeStream(bufferingPolicy: .bufferingNewest(8))
    installSystemListeners()
    monitor = Task { [weak self] in
      for await trigger in stream {
        guard let self else { return }
        await self.handle(trigger)
      }
    }
    last = readSnapshot()
    syncDynamicListeners()
  }

  private func installSystemListeners() {
    let hub = triggers
    let selectors = [
      kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
      kAudioHardwarePropertyProcessObjectList,
    ]
    do {
      systemListener = try PropertyListener(
        object: AudioProperty.system, addresses: selectors.map { AudioProperty.address($0) },
        queue: queue, handler: { hub.yield(.changed) })
      restartListener = try PropertyListener(
        object: AudioProperty.system,
        addresses: [AudioProperty.address(kAudioHardwarePropertyServiceRestarted)],
        queue: queue, handler: { hub.yield(.serviceRestarted) })
    } catch {
      AudioLog.logger.error("system listeners failed: \(error.description, privacy: .public)")
    }
  }

  private func handle(_ trigger: Trigger) {
    if trigger == .serviceRestarted {
      systemListener = nil
      restartListener = nil
      processListeners.removeAll()
      masterListener = nil
      masterDeviceID = AudioProperty.unknown
      installSystemListeners()
    }
    syncDynamicListeners()
    publish(forced: trigger == .serviceRestarted)
  }

  /// Keeps one `IsRunningOutput`/`IsRunningInput` listener per process and the volume and
  /// activity listeners on the default device.
  private func syncDynamicListeners() {
    let hub = triggers
    let present = Set(catalog.objectIDs())
    for object in processListeners.keys where !present.contains(object) {
      processListeners.removeValue(forKey: object)
    }
    for object in present where processListeners[object] == nil {
      do {
        processListeners[object] = try PropertyListener(
          object: object,
          addresses: [
            AudioProperty.address(kAudioProcessPropertyIsRunningOutput),
            AudioProperty.address(kAudioProcessPropertyIsRunningInput),
          ],
          queue: queue, handler: { hub.yield(.changed) })
      } catch {
        AudioLog.logger.error(
          "process listener failed: \(error.description, privacy: .public)")
      }
    }
    let defaultID = DeviceCatalog.defaultOutputID() ?? AudioProperty.unknown
    if defaultID != masterDeviceID {
      masterDeviceID = defaultID
      masterListener = nil
      if defaultID != AudioProperty.unknown {
        let scope = kAudioObjectPropertyScopeOutput
        do {
          masterListener = try PropertyListener(
            object: defaultID,
            addresses: [
              AudioProperty.address(AudioProperty.virtualMainVolume, scope: scope),
              AudioProperty.address(kAudioDevicePropertyMute, scope: scope),
              AudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: 1),
              // Per-process `IsRunningOutput` notifications are not always delivered (measured:
              // none arrived for a process that started and stopped output). The device
              // notification is, so an app that starts playing is still noticed (no polling).
              AudioProperty.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
            ],
            queue: queue, handler: { hub.yield(.changed) })
        } catch {
          AudioLog.logger.error(
            "output device listener failed: \(error.description, privacy: .public)")
        }
      }
    }
  }

  private func readSnapshot() -> AudioSystemSnapshot {
    let defaultID = DeviceCatalog.defaultOutputID()
    return AudioSystemSnapshot(
      processes: catalog.processes(),
      devices: DeviceCatalog.outputDevices(),
      defaultOutputUID: DeviceCatalog.defaultOutputUID(),
      master: defaultID.flatMap { DeviceCatalog.master(of: $0) })
  }

  private func publish(forced: Bool) {
    let new = readSnapshot()
    let old = last
    last = new
    if forced || old?.devices != new.devices { hub.yield(.devices(new.devices)) }
    if forced || old?.defaultOutputUID != new.defaultOutputUID {
      hub.yield(.defaultOutput(uid: new.defaultOutputUID))
    }
    if forced || old?.processes != new.processes { hub.yield(.processes(new.processes)) }
    if let master = new.master, forced || old?.master != master { hub.yield(.master(master)) }
  }
}
