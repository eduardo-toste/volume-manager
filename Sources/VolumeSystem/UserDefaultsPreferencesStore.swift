import Foundation
import VolumeCore
import os

/// The slice of `UserDefaults` the store uses, so tests can use memory instead of a plist file.
protocol PreferencesBackend {
  func object(forKey key: String) -> Any?
  func set(_ value: Any?, forKey key: String)
  func removeObject(forKey key: String)
}

extension UserDefaults: PreferencesBackend {}

/// `PreferencesStore` backed by `UserDefaults`.
///
/// The app uses `UserDefaults.standard`: inside the app bundle that is the
/// `com.volumemanager.app` domain (a suite named like the main bundle is not allowed by the
/// system). Tests inject an isolated suite instead. Only simple property-list values are
/// written; anything else is dropped with a log line instead of crashing. Validation of what
/// is read back stays in the domain (SPEC 12.9.4).
@MainActor
public final class UserDefaultsPreferencesStore: PreferencesStore {
  /// Longest key accepted, in UTF-8 bytes (and therefore in characters).
  public static let maxKeyLength = 200
  /// Deepest nesting of arrays and dictionaries accepted.
  static let maxDepth = 4

  private let defaults: any PreferencesBackend
  private let logger = Logger(
    subsystem: AppIdentity.logSubsystem, category: VolumeSystemModule.logCategory)

  /// Creates a store over `defaults` (pass an isolated suite in tests).
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Creates a store over any backend (an in-memory fake in tests, so no file is created).
  init(backend: any PreferencesBackend) {
    self.defaults = backend
  }

  /// The stored property-list value for `key`, or `nil`.
  public func object(forKey key: String) -> Any? {
    guard Self.isValid(key: key) else { return nil }
    return defaults.object(forKey: key)
  }

  /// Stores `value`, or removes the key when `value` is `nil`. Invalid keys and values that are
  /// not simple property-list data are ignored.
  public func set(_ value: Any?, forKey key: String) {
    guard Self.isValid(key: key) else {
      logger.error("Ignored write with an invalid key")
      return
    }
    guard let value else {
      defaults.removeObject(forKey: key)
      return
    }
    guard Self.isSimplePropertyList(value, depth: 0) else {
      logger.error("Ignored write of a non-property-list value for \(key, privacy: .private)")
      return
    }
    defaults.set(value, forKey: key)
  }

  private static func isValid(key: String) -> Bool {
    !key.isEmpty && key.utf8.count <= maxKeyLength
  }

  /// True for strings, numbers, booleans, dates, data, and arrays or string-keyed dictionaries
  /// of those, within `maxDepth`.
  static func isSimplePropertyList(_ value: Any, depth: Int) -> Bool {
    guard depth <= maxDepth else { return false }
    switch value {
    case let number as NSNumber:
      return number.doubleValue.isFinite
    case is String, is Date, is Data:
      return true
    case let array as [Any]:
      return array.allSatisfy { isSimplePropertyList($0, depth: depth + 1) }
    case let dictionary as [String: Any]:
      return dictionary.values.allSatisfy { isSimplePropertyList($0, depth: depth + 1) }
    default:
      return false
    }
  }
}
