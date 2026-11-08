import CoreAudio
import os

/// A Core Audio failure with the context needed to understand it (SPEC 12.3: every `OSStatus`
/// is checked and converted).
public struct AudioError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The raw status returned by Core Audio.
  public let status: OSStatus
  /// What was being attempted (property, object, step). Never contains audio content.
  public let context: String
  /// The step that failed, for decisions that must not depend on the text of `context`.
  public let stage: Stage

  /// Steps of building a tap that callers need to tell apart.
  public enum Stage: Sendable, Hashable {
    /// Creating the process tap itself (this is where a refused permission shows).
    case createTap
    /// Any other step.
    case other
  }

  /// Creates an error.
  public init(status: OSStatus, context: String, stage: Stage = .other) {
    self.status = status
    self.context = context
    self.stage = stage
  }

  /// The status as a four-character code when it is printable, otherwise `"n/a"`.
  public var fourCharacterCode: String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "n/a" }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Readable text for logs and `vmctl`.
  public var description: String {
    "\(context): OSStatus \(status) (\(fourCharacterCode))"
  }

  /// Throws `AudioError` unless `status` is `noErr`.
  static func check(
    _ status: OSStatus, _ context: @autoclosure () -> String, stage: Stage = .other
  ) throws(AudioError) {
    guard status == noErr else {
      throw AudioError(status: status, context: context(), stage: stage)
    }
  }

  /// An error for a condition Core Audio did not report (for example, an unknown device).
  static func unsupported(_ context: String, stage: Stage = .other) -> AudioError {
    AudioError(status: kAudioHardwareUnsupportedOperationError, context: context, stage: stage)
  }
}

/// Shared logger for the module (subsystem of SPEC 12.3).
enum AudioLog {
  static let logger = Logger(subsystem: "com.volumemanager.app", category: "audio")
}
