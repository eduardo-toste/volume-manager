import Foundation

/// Validation of values read from storage. Anything unexpected becomes `nil` and the caller
/// falls back to the safe default (SPEC 12.9.4).
enum PreferenceValidation {
  /// Longest device UID accepted, in characters.
  static let maxUIDLength = 200
  /// Most remembered apps accepted from storage.
  static let maxRememberedApps = 1000

  static func bool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, isBoolean(number) else { return nil }
    return number.boolValue
  }

  private static func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  static func string(_ value: Any?) -> String? {
    guard let text = value as? String, text.utf8.count <= maxUIDLength * 4,
      text.count <= maxUIDLength
    else { return nil }
    return text
  }

  /// A volume in `0...1`, or `nil` if the value is not a finite number in range.
  static func volume(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
    let volume = number.doubleValue
    guard volume.isFinite, volume >= 0, volume <= 1 else { return nil }
    return volume
  }

  /// A plain integer, or `nil`.
  static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double == double.rounded(), abs(double) < 1e9 else { return nil }
    return Int(double)
  }

  /// A UID that is plain text: not empty, not too long, nothing the sanitizer would remove.
  static func uid(_ value: Any?) -> String? {
    guard let text = string(value), !text.isEmpty, TextSanitizer.clean(text) == text else {
      return nil
    }
    return text
  }
}
