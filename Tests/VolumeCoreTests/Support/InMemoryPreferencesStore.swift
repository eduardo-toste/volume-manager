@testable import VolumeCore

/// A dictionary-backed store that counts writes. Tests may seed it with hostile values.
@MainActor
final class InMemoryPreferencesStore: PreferencesStore {
  private(set) var values: [String: Any]
  private(set) var writeCount = 0

  init(_ values: [String: Any] = [:]) { self.values = values }

  func object(forKey key: String) -> Any? { values[key] }

  func set(_ value: Any?, forKey key: String) {
    writeCount += 1
    values[key] = value
  }
}
