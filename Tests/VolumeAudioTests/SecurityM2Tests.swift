import CoreAudio
import Dispatch
import Foundation
import Synchronization
import Testing
import VolumeCore

@testable import VolumeAudio

// Security M2: adversarial proofs. Meant to be run also under the sanitizers:
//   swift test --sanitize=address --filter SecurityM2
//   swift test --sanitize=thread --filter SecurityM2
// No sound: the hardware part only taps this test's own `afplay -v 0`.

/// Buffer lists whose data blocks have exactly `mDataByteSize` bytes, so AddressSanitizer
/// reports any read or write one byte past the end.
private final class ExactBufferList {
  private let raw: UnsafeMutableRawPointer
  private var blocks: [UnsafeMutableRawPointer] = []
  let list: UnsafeMutablePointer<AudioBufferList>

  /// `buffers`: (channels, byte size, has data).
  init(_ buffers: [(channels: UInt32, bytes: Int, hasData: Bool)], fill: UInt8) {
    let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
    let size = max(
      MemoryLayout<AudioBufferList>.size, header + buffers.count * MemoryLayout<AudioBuffer>.stride)
    raw = .allocate(byteCount: size, alignment: 16)
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(buffers.count)
    let pointer = UnsafeMutableAudioBufferListPointer(list)
    for (index, buffer) in buffers.enumerated() {
      var data: UnsafeMutableRawPointer?
      if buffer.hasData {
        // At least 1 byte so the pointer is valid; only `bytes` are declared.
        let block = UnsafeMutableRawPointer.allocate(byteCount: max(buffer.bytes, 1), alignment: 4)
        block.initializeMemory(as: UInt8.self, repeating: fill, count: max(buffer.bytes, 1))
        blocks.append(block)
        data = block
      }
      pointer[index] = AudioBuffer(
        mNumberChannels: buffer.channels, mDataByteSize: UInt32(buffer.bytes), mData: data)
    }
  }

  deinit {
    for block in blocks { block.deallocate() }
    raw.deallocate()
  }
}

/// Small deterministic generator (no Foundation randomness, reproducible failures).
private struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@Suite("Security M2: IOProc memory (exact-size buffers)")
struct SecurityM2MemoryTests {
  /// Random shapes, odd byte sizes, missing data, channel mismatches and hostile offsets:
  /// `render` must never touch a byte outside the declared buffers (ASan run).
  @Test func renderNeverLeavesTheDeclaredBuffers() {
    var rng = SplitMix(state: 0x5EC0_0002)
    let offsets = [0, 1, -1, 2, 3, Int.max, Int.min, Int.max - 1]
    for _ in 0..<3_000 {
      let inputs = (0..<Int.random(in: 0...4, using: &rng)).map { _ in
        (
          channels: UInt32.random(in: 0...3, using: &rng),
          bytes: Int.random(in: 0...67, using: &rng),
          hasData: Int.random(in: 0...9, using: &rng) > 0
        )
      }
      let outputs = (0..<Int.random(in: 0...3, using: &rng)).map { _ in
        (
          channels: UInt32.random(in: 0...3, using: &rng),
          bytes: Int.random(in: 0...67, using: &rng),
          hasData: Int.random(in: 0...9, using: &rng) > 0
        )
      }
      let input = ExactBufferList(inputs, fill: 0x3F)
      let output = ExactBufferList(outputs, fill: 0xAA)
      let state = RealtimeTapState(
        initialGain: Float.random(in: 0...1, using: &rng),
        target: Float.random(in: -1...2, using: &rng), step: 0.01)
      state.setInputOffset(offsets[Int.random(in: 0..<offsets.count, using: &rng)])
      state.render(input: UnsafePointer(input.list), output: output.list)
    }
  }

  /// The access probe's scan reads only declared bytes, even for odd sizes.
  @Test func signalScanNeverLeavesTheDeclaredBuffers() {
    var rng = SplitMix(state: 0x5EC0_0003)
    for _ in 0..<2_000 {
      let shapes = (0..<Int.random(in: 0...4, using: &rng)).map { _ in
        (
          channels: UInt32.random(in: 0...2, using: &rng),
          bytes: Int.random(in: 0...35, using: &rng),
          hasData: Int.random(in: 0...5, using: &rng) > 0
        )
      }
      let list = ExactBufferList(shapes, fill: 0)
      let probe = SignalProbeState()
      probe.scan(UnsafePointer(list.list))
      #expect(probe.sawSignal == false)
    }
  }

  /// Negative zero is "no signal" for the silence guard, and a 3-byte tail is never read.
  @Test func signalScanIgnoresTrailingPartialWord() {
    let list = ExactBufferList([(channels: 1, bytes: 7, hasData: true)], fill: 0)
    let data = UnsafeMutableAudioBufferListPointer(list.list)[0].mData
    // Bytes 4...6 (the partial word) are non-zero; only whole words are inspected.
    data?.storeBytes(of: 0x8000_0000 as UInt32, as: UInt32.self)
    (data.map { $0 + 4 })?.initializeMemory(as: UInt8.self, repeating: 0xFF, count: 3)
    let probe = SignalProbeState()
    probe.scan(UnsafePointer(list.list))
    #expect(probe.sawSignal == false)
  }
}

/// Records how many times `stop` ran, from any thread.
private final class CountingHandle: TapHandle {
  private let stops = Atomic<Int>(0)
  var stopCount: Int { stops.load(ordering: .relaxed) }
  var framesProcessed: UInt64 { 0 }
  func consumeSignalFlag() -> Bool { false }
  var hasFault: Bool { false }
  func setTarget(gain: Float) {}
  func stop() { stops.add(1, ordering: .relaxed) }
  var diagnostics: TapDiagnostics {
    TapDiagnostics(
      appID: "x", pids: [], deviceUID: "", framesProcessed: 0, hasSeenSignal: false,
      tapFormat: "", outputFormat: "")
  }
}

@Suite("Security M2: races between reconcile, restoreAll and the kill list")
struct SecurityM2RaceTests {
  private func app(_ index: Int) -> ControlledApp {
    ControlledApp(id: "sec.app\(index)", bundleID: "sec.app\(index)", pids: [Int32(100 + index)])
  }

  /// Reconciles (create, update, move between devices, remove) race with `restoreAll`. Once
  /// everything settled and a final `restoreAll` returned, no tap may be alive and the kill
  /// list must be empty.
  @Test func reconcileStormAgainstRestoreAllLeavesNoLiveTap() async {
    let engine = FakeTapEngine()
    engine.setDevice("SPK")
    engine.setDevice("PODS", rate: 24_000, id: 2)
    var policy = WatchdogPolicy()
    policy.tick = .seconds(3_600)
    policy.crossfade = .milliseconds(1)
    let controller = CoreAudioAppController(
      engine: engine, clock: ContinuousClock(), policy: policy)
    await withTaskGroup(of: Void.self) { group in
      for round in 0..<200 {
        group.addTask {
          let desired = (0..<(round % 4)).map { index in
            DesiredAppAudio(
              app: app(index), gain: Float(round % 10) / 10, muted: round % 7 == 0,
              targetDeviceUID: (round + index) % 3 == 0 ? "PODS" : "SPK")
          }
          await controller.reconcile(desired: desired)
        }
        if round % 5 == 0 { group.addTask { await controller.restoreAll() } }
      }
    }
    await controller.restoreAll()
    #expect(engine.live.isEmpty)
    #expect(controller.killList.count == 0)
    #expect(await controller.diagnostics().isEmpty)
  }

  /// `stopAll` from many threads at once, while handles are added: each handle stops at least
  /// once and nothing is left registered.
  @Test func killListConcurrentStopAll() {
    let list = KillList()
    let handles = (0..<200).map { _ in CountingHandle() }
    DispatchQueue.concurrentPerform(iterations: 400) { index in
      if index < 200 {
        _ = list.add(handles[index])
      } else {
        list.stopAll()
      }
    }
    list.stopAll()
    #expect(list.count == 0)
    #expect(handles.allSatisfy { $0.stopCount >= 1 })
  }
}

private struct NoInfo: AppInfoProvider {
  func executablePath(forPID pid: Int32) -> String? { nil }
  func appName(atAppPath appPath: String) -> String? { nil }
  func bundleID(atAppPath appPath: String) -> String? { nil }
}

@Suite("Security M2: text from other processes")
struct SecurityM2TextTests {
  /// Core Audio hands over the bundle ID exactly as the process declared it (reproduced with a
  /// bundle whose CFBundleIdentifier contains ESC sequences). The domain must drop it.
  @Test func bundleIDWithTerminalEscapesNeverReachesTheMixer() {
    let hostile = AudioProcessInfo(
      pid: 4242, bundleID: "com.evil.x\u{1B}]0;PWNED\u{07}\u{1B}[2J", isRunningOutput: true)
    #expect(ProcessGrouping.group([hostile], info: NoInfo()).isEmpty)
  }

  /// Documents the behaviour behind finding B-3: any process can claim Volume's own bundle ID
  /// and is then hidden from the mixer.
  @Test func claimingVolumesBundleIDHidesAProcess() {
    let hidden = AudioProcessInfo(
      pid: 4243, bundleID: AppIdentity.bundleIdentifier + ".helper", isRunningOutput: true)
    #expect(ProcessGrouping.group([hidden], info: NoInfo()).isEmpty)
  }

  /// Documents finding B-3: an unbundled process that claims another app's bundle ID joins
  /// that app's group (and its tap).
  @Test func claimingAnotherBundleIDJoinsThatGroup() {
    let real = AudioProcessInfo(pid: 10, bundleID: "com.vendor.Player", isRunningOutput: true)
    let impostor = AudioProcessInfo(
      pid: 11, bundleID: "com.vendor.Player.fake", isRunningOutput: true)
    let groups = ProcessGrouping.group([real, impostor], info: NoInfo())
    #expect(groups.count == 1)
    #expect(groups.first?.pids == [10, 11])
  }
}

// Hardware: part of the serialized suite so no other test creates aggregates meanwhile.
extension HardwareTests {
  private func ownAggregates() -> Set<String> {
    Set(AudioDiagnostics.deviceUIDs().filter { $0.hasPrefix(DeviceCatalog.aggregateUIDPrefix) })
  }

  /// `stop()` from 8 threads plus the kill list, while the IOProc runs, then the last reference
  /// is dropped. Under ASan this proves the IOProc never runs on freed state; afterwards no
  /// aggregate remains.
  @Test func securityConcurrentStopWhileIORunsIsSafe() async throws {
    guard let player = await SilentPlayer() else { return }
    defer { player.stop() }
    let catalog = ProcessCatalog()
    guard let object = catalog.objectID(forPID: player.pid),
      let speaker = DeviceCatalog.outputDevices().first(where: { $0.kind == .builtIn })
        ?? DeviceCatalog.outputDevices().first,
      let signature = DeviceCatalog.signature(forUID: speaker.uid)
    else { return }
    let before = ownAggregates()
    let request = TapRequest(
      app: ControlledApp(id: "pid:\(player.pid)", bundleID: nil, pids: [player.pid]),
      pids: [player.pid], device: signature, initialGain: 1, targetGain: 0)
    var started = 0
    for _ in 0..<15 {
      guard
        let session = try? CoreAudioTapSession.start(
          request, objectIDs: [object], queue: DispatchQueue(label: "sec"), notify: { _ in },
          isCancelled: { false })
      else { continue }
      started += 1
      let list = KillList()
      _ = list.add(session)
      try await Task.sleep(for: .milliseconds(40))
      DispatchQueue.concurrentPerform(iterations: 9) { index in
        if index == 0 { list.stopAll() } else { session.stop() }
      }
    }
    #expect(started > 0)
    try await Task.sleep(for: .milliseconds(1_000))
    #expect(ownAggregates() == before)
  }
}
