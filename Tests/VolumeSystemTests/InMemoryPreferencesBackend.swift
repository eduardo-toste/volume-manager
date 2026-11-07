import Foundation

@testable import VolumeSystem

/// Memory-only stand-in for `UserDefaults`: tests that use it create no file in
/// `~/Library/Preferences`. Like `UserDefaults`, it keeps only what a property list can hold.
final class InMemoryPreferencesBackend: PreferencesBackend {
  private var storage: [String: Any] = [:]

  func object(forKey key: String) -> Any? { storage[key] }
  func set(_ value: Any?, forKey key: String) { storage[key] = value }
  func removeObject(forKey key: String) { storage[key] = nil }
  func dictionaryRepresentation() -> [String: Any] { storage }
}
