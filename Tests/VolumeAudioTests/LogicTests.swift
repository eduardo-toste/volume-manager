import CoreAudio
import Testing
import VolumeCore

@testable import VolumeAudio

private func layout(_ rate: Double = 48_000, _ channels: UInt32 = 2, interleaved: Bool = true)
  -> StreamLayout
{
  StreamLayout(sampleRate: rate, channels: channels, isInterleaved: interleaved)
}

@Suite("Format policy (M0.5 recommendation 1)", .timeLimit(.minutes(1)))
struct FormatPolicyTests {
  @Test func acceptsMatchingStereoAndReturnsTheTapOffset() throws {
    #expect(
      try FormatPolicy.validate(tap: layout(), output: layout(), inputShape: [2], outputShape: [2])
        == 0)
    #expect(
      try FormatPolicy.validate(
        tap: layout(48_000), output: layout(24_000), inputShape: [1, 2], outputShape: [2]) == 1)
    #expect(
      try FormatPolicy.validate(
        tap: layout(interleaved: false), output: layout(interleaved: false),
        inputShape: [1, 1], outputShape: [1, 1]) == 0)
  }

  @Test func rejectsEverythingThatWouldNeedConversion() {
    func mismatch(_ tap: StreamLayout, _ output: StreamLayout, _ input: [UInt32], _ out: [UInt32])
      -> FormatMismatch?
    {
      do {
        _ = try FormatPolicy.validate(tap: tap, output: output, inputShape: input, outputShape: out)
        return nil
      } catch { return error }
    }
    var int16 = layout()
    int16.isFloat32 = false
    #expect(mismatch(int16, layout(), [2], [2]) == .notFloat32)
    #expect(mismatch(layout(), int16, [2], [2]) == .notFloat32)
    #expect(mismatch(layout(48_000, 1), layout(), [1], [2]) == .channelCount(tap: 1, output: 2))
    #expect(mismatch(layout(interleaved: false), layout(), [2], [2]) == .interleaving)
    #expect(mismatch(layout(), layout(), [1, 1], [2]) == .bufferShape)
    #expect(mismatch(layout(), layout(), [], [2]) == .bufferShape)
    #expect(mismatch(layout(), layout(), [2], []) == .bufferShape)
    #expect(mismatch(layout(), layout(), [2], [2, 2]) == .bufferShape)
  }

  @Test func outputMustBeFloatAndMonoOrStereo() {
    #expect(throws: FormatMismatch.unsupportedChannelCount(6)) {
      try FormatPolicy.validateOutput(layout(48_000, 6))
    }
    #expect(throws: FormatMismatch.notFloat32) {
      var bad = layout()
      bad.isLinearPCM = false
      try FormatPolicy.validateOutput(bad)
    }
    #expect(throws: Never.self) { try FormatPolicy.validateOutput(layout(48_000, 1)) }
    #expect(FormatPolicy.tapChannels(forOutputChannels: 0) == nil)
  }

  @Test func layoutReadsTheStreamDescription() {
    var description = AudioStreamBasicDescription(
      mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
      mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
    let stereo = StreamLayout(description)
    #expect(stereo.isFloat32 && stereo.isInterleaved && stereo.channels == 2)
    description.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
    #expect(StreamLayout(description).isInterleaved == false)
    description.mBitsPerChannel = 16
    #expect(StreamLayout(description).isFloat32 == false)
  }
}

@Suite("Session health (watchdog logic)", .timeLimit(.minutes(1)))
struct SessionHealthTests {
  let policy = WatchdogPolicy()

  @Test func ticksFromLimits() {
    #expect(policy.ticks(for: .seconds(2)) == 4)
    #expect(WatchdogPolicy(tick: .seconds(1)).ticks(for: .milliseconds(1500)) == 2)
  }

  @Test func stalledFramesWhileTheAppPlays() {
    var health = SessionHealth(policy: policy)
    _ = health.evaluate(frames: 100, sawSignal: true, appRunning: true, fault: false)
    var verdicts: [HealthVerdict] = []
    for _ in 0..<4 {
      verdicts.append(
        health.evaluate(frames: 100, sawSignal: false, appRunning: true, fault: false))
    }
    #expect(verdicts == [.healthy, .healthy, .healthy, .stalled])
  }

  /// Round 5b (120 s since M5.3): silence is reported once after `silenceLimit` and then
  /// latched until signal returns, so a silent stream asks for one check per silent period.
  @Test func silenceIsReportedOnceAfterTheLimitAndLatched() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    var verdicts: [HealthVerdict] = []
    let silence = policy.ticks(for: policy.silenceLimit)
    #expect(silence == 240)
    for _ in 0..<(silence * 3) {
      frames += 24_000
      verdicts.append(
        health.evaluate(frames: frames, sawSignal: false, appRunning: true, fault: false))
    }
    #expect(
      Array(verdicts.prefix(silence)) == Array(repeating: .healthy, count: silence - 1) + [.silent])
    #expect(verdicts.filter { $0 == .silent }.count == 1)
  }

  /// C2 (M5.3): stopping the output does not forgive the silence; only the output time counts
  /// and only a non-zero sample resets it. A revoked permission with an app that plays on and
  /// off still reaches the check.
  @Test func pausesNeitherCountNorResetTheSilence() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    let silence = policy.ticks(for: policy.silenceLimit)
    var runningTicks = 0
    var verdict = HealthVerdict.healthy
    var tick = 0
    while verdict != .silent && tick < silence * 10 {
      frames += 24_000
      let running = (tick / 4) % 2 == 0  // 2 s playing, 2 s paused, repeated
      if running { runningTicks += 1 }
      verdict = health.evaluate(frames: frames, sawSignal: false, appRunning: running, fault: false)
      tick += 1
    }
    #expect(verdict == .silent)
    #expect(runningTicks == silence, "only the output time counts")
  }

  /// SPEC 4.6 (M5.3): a new tap may take up to 5 s to deliver its first frame (Bluetooth);
  /// after the first frame the limit is 2 s.
  @Test func aSlowStartIsNotAStallBeforeFiveSeconds() {
    var health = SessionHealth(policy: policy)
    let start = policy.ticks(for: policy.startLimit)
    var verdicts: [HealthVerdict] = []
    for _ in 0..<start {
      verdicts.append(health.evaluate(frames: 0, sawSignal: false, appRunning: true, fault: false))
    }
    #expect(verdicts == Array(repeating: .healthy, count: start - 1) + [.stalled])
    var late = SessionHealth(policy: policy)
    for _ in 0..<(start - 1) {
      #expect(
        late.evaluate(frames: 0, sawSignal: false, appRunning: true, fault: false) == .healthy)
    }
    #expect(late.evaluate(frames: 512, sawSignal: true, appRunning: true, fault: false) == .healthy)
    var after: [HealthVerdict] = []
    for _ in 0..<policy.ticks(for: policy.stallLimit) {
      after.append(late.evaluate(frames: 512, sawSignal: false, appRunning: true, fault: false))
    }
    #expect(after.last == .stalled, "2 s once the first frame arrived")
    #expect(after.dropLast().allSatisfy { $0 == .healthy })
  }

  /// S41R-M1: only a silence that already had a check is a "repeat"; real sound resets it.
  @Test func aSilenceIsARepeatOnlyAfterItsCheckAndUntilSignalReturns() {
    var health = SessionHealth(policy: policy)
    #expect(!health.silenceWasChecked)
    health.retryLater()
    #expect(health.silenceWasChecked)
    _ = health.evaluate(frames: 1, sawSignal: true, appRunning: true, fault: false)
    #expect(!health.silenceWasChecked)
  }

  @Test func signalReArmsTheSilenceReport() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    var reports = 0
    for period in 0..<3 {
      frames += 24_000
      _ = health.evaluate(frames: frames, sawSignal: true, appRunning: true, fault: false)
      for _ in 0..<(policy.ticks(for: policy.silenceLimit) + period) {
        frames += 24_000
        let verdict = health.evaluate(
          frames: frames, sawSignal: false, appRunning: true, fault: false)
        if verdict == .silent { reports += 1 }
      }
    }
    #expect(reports == 3, "one per silent period")
  }

  @Test func inconclusiveCheckAsksAgainOnlyAfterThirtySeconds() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    func tick() -> HealthVerdict {
      frames += 24_000
      return health.evaluate(frames: frames, sawSignal: false, appRunning: true, fault: false)
    }
    for _ in 0..<4 { _ = tick() }
    health.retryLater()
    let retry = policy.ticks(for: policy.recheckAfter)
    var verdicts: [HealthVerdict] = []
    for _ in 0..<(retry + 10) { verdicts.append(tick()) }
    #expect(verdicts.firstIndex(of: .silent) == retry - 1)
    #expect(verdicts.filter { $0 == .silent }.count == 1)
  }

  @Test func silenceIsNotCountedWhileTheAppIsNotRunningAndSignalResetsIt() {
    var health = SessionHealth(policy: policy)
    var frames: UInt64 = 0
    for tick in 0..<40 {
      frames += 1000
      // Two silent ticks, then one with signal, forever: never reaches four in a row.
      let verdict = health.evaluate(
        frames: frames, sawSignal: tick % 3 == 2, appRunning: true, fault: false)
      #expect(verdict == .healthy)
    }
    for _ in 0..<40 {
      frames += 1000
      #expect(
        health.evaluate(frames: frames, sawSignal: false, appRunning: false, fault: false)
          == .healthy)
    }
  }

  @Test func faultWinsImmediately() {
    var health = SessionHealth(policy: policy)
    #expect(health.evaluate(frames: 5, sawSignal: true, appRunning: true, fault: true) == .faulted)
  }
}

@Suite("Reconcile planner (recommendations 9 and 11)", .timeLimit(.minutes(1)))
struct ReconcilePlannerTests {
  func key(
    pids: [Int32] = [1], uid: String = "A", rate: Double = 48_000, generation: Int = 0,
    id: UInt32 = 5
  ) -> SessionKey {
    SessionKey(
      pids: pids, deviceUID: uid,
      device: DeviceSignature(id: id, uid: uid, rawUID: uid, layout: layout(rate)),
      serviceGeneration: generation
    )
  }

  @Test func planTable() {
    #expect(ReconcilePlanner.plan(current: nil, wanted: nil) == .none)
    #expect(ReconcilePlanner.plan(current: nil, wanted: key()) == .create)
    #expect(ReconcilePlanner.plan(current: key(), wanted: nil) == .destroy)
    #expect(ReconcilePlanner.plan(current: key(), wanted: key()) == .update)
    #expect(ReconcilePlanner.plan(current: key(), wanted: key(pids: [1, 2])) == .replaceGracefully)
    #expect(ReconcilePlanner.plan(current: key(), wanted: key(uid: "B")) == .replaceGracefully)
    #expect(ReconcilePlanner.plan(current: key(), wanted: key(rate: 44_100)) == .replaceGracefully)
    #expect(ReconcilePlanner.plan(current: key(), wanted: key(generation: 1)) == .replaceHard)
  }
}

@Suite("Small pieces", .timeLimit(.minutes(1)))
struct SmallPieceTests {
  @Test func transportTypesMapToKinds() {
    #expect(OutputDeviceKind(transportType: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
    #expect(OutputDeviceKind(transportType: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
    #expect(OutputDeviceKind(transportType: kAudioDeviceTransportTypeHDMI) == .display)
    #expect(OutputDeviceKind(transportType: kAudioDeviceTransportTypeAirPlay) == .airPlay)
    #expect(OutputDeviceKind(transportType: kAudioDeviceTransportTypeUSB) == .usb)
    #expect(OutputDeviceKind(transportType: kAudioDeviceTransportTypeVirtual) == .virtual)
    #expect(OutputDeviceKind(transportType: 0) == .other)
  }

  @Test func accessDecision() {
    #expect(AccessDecision.verdict(sawSignal: true, stillPlaying: false) == .granted)
    #expect(AccessDecision.verdict(sawSignal: false, stillPlaying: true) == .denied)
    #expect(AccessDecision.verdict(sawSignal: false, stillPlaying: false) == .indeterminate)
  }

  @Test func audioErrorDescribesItself() {
    let error = AudioError(status: 0x7768_6174, context: "get thing")
    #expect(error.fourCharacterCode == "what")
    #expect(error.description.contains("get thing"))
    #expect(AudioError(status: -1, context: "x").fourCharacterCode == "n/a")
  }

  @Test func eventHubDeliversToEveryoneAndForgetsFinishedStreams() async {
    let hub = EventHub<Int>()
    let first = hub.makeStream()
    var second: AsyncStream<Int>? = hub.makeStream()
    #expect(hub.subscriberCount == 2)
    hub.yield(1)
    var iterator = first.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    second = nil
    _ = second
    for _ in 0..<100 where hub.subscriberCount != 1 { await Task.yield() }
    #expect(hub.subscriberCount == 1)
    hub.finishAll()
    #expect(await iterator.next() == nil)
  }
}
