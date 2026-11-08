import CoreAudio

/// The parts of an `AudioStreamBasicDescription` that decide whether the gain kernel may touch
/// the samples (SPEC 4.7: Float32 only, no conversion).
struct StreamLayout: Sendable, Hashable {
  var sampleRate: Double
  var channels: UInt32
  var isLinearPCM: Bool
  var isFloat32: Bool
  var isInterleaved: Bool

  init(
    sampleRate: Double, channels: UInt32, isLinearPCM: Bool = true, isFloat32: Bool = true,
    isInterleaved: Bool = true
  ) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.isLinearPCM = isLinearPCM
    self.isFloat32 = isFloat32
    self.isInterleaved = isInterleaved
  }

  init(_ description: AudioStreamBasicDescription) {
    let flags = description.mFormatFlags
    sampleRate = description.mSampleRate
    channels = description.mChannelsPerFrame
    isLinearPCM = description.mFormatID == kAudioFormatLinearPCM
    isFloat32 =
      description.mBitsPerChannel == 32 && flags & kAudioFormatFlagIsFloat != 0
      && flags & kAudioFormatFlagIsBigEndian == 0
    isInterleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
  }

  /// Short text such as `48000 Hz, 2 ch, float32, interleaved`.
  var summary: String {
    "\(Int(sampleRate)) Hz, \(channels) ch, \(isLinearPCM ? (isFloat32 ? "float32" : "other PCM") : "not PCM"), "
      + (isInterleaved ? "interleaved" : "non-interleaved")
  }
}

/// Why a tap and an output cannot be joined without converting samples.
enum FormatMismatch: Error, Sendable, Hashable {
  case notFloat32
  case unsupportedChannelCount(UInt32)
  case channelCount(tap: UInt32, output: UInt32)
  case interleaving
  case bufferShape
}

/// Format rules that must hold before a tap is allowed to mute an app (SPEC 4.6, 4.7).
enum FormatPolicy {
  /// How many channels the tap must deliver for an output with `channels`, or `nil` when this
  /// version cannot match it (the app then keeps its original sound).
  static func tapChannels(forOutputChannels channels: UInt32) -> UInt32? {
    (channels == 1 || channels == 2) ? channels : nil
  }

  /// Checks the output device format before any tap exists.
  static func validateOutput(_ output: StreamLayout) throws(FormatMismatch) {
    guard output.isLinearPCM, output.isFloat32 else { throw .notFloat32 }
    guard tapChannels(forOutputChannels: output.channels) != nil else {
      throw .unsupportedChannelCount(output.channels)
    }
  }

  /// Checks tap and output together, with the buffer shapes of the aggregate device. Returns
  /// the index of the first aggregate input buffer that carries the tap (sub-devices with input
  /// streams come first).
  static func validate(
    tap: StreamLayout, output: StreamLayout, inputShape: [UInt32], outputShape: [UInt32]
  ) throws(FormatMismatch) -> Int {
    guard tap.isLinearPCM, tap.isFloat32, output.isLinearPCM, output.isFloat32 else {
      throw .notFloat32
    }
    guard tap.channels == output.channels else {
      throw .channelCount(tap: tap.channels, output: output.channels)
    }
    guard tap.isInterleaved == output.isInterleaved else { throw .interleaving }
    guard !outputShape.isEmpty, inputShape.count >= outputShape.count,
      outputShape.allSatisfy({ $0 > 0 }),
      outputShape.reduce(0, +) == output.channels
    else { throw .bufferShape }
    let offset = inputShape.count - outputShape.count
    guard Array(inputShape[offset...]) == outputShape else { throw .bufferShape }
    return offset
  }
}
