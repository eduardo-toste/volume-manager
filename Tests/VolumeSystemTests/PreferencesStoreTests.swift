import Foundation
import Testing
import VolumeCore

@testable import VolumeSystem

@MainActor
@Suite("UserDefaultsPreferencesStore", .timeLimit(.minutes(1)))
struct PreferencesStoreTests {
  /// Runs `body` over an in-memory backend, so no preferences file is ever created.
  private func withStore(
    _ body: (UserDefaultsPreferencesStore, InMemoryPreferencesBackend) throws -> Void
  ) throws {
    let backend = InMemoryPreferencesBackend()
    try body(UserDefaultsPreferencesStore(backend: backend), backend)
  }

  @Test func roundTripsSimpleValues() throws {
    try withStore { store, _ in
      store.set(true, forKey: "flag")
      store.set(0.5, forKey: "volume")
      store.set("uid", forKey: "device")
      store.set(["a": 1, "b": [true, "x"]] as [String: Any], forKey: "nested")
      #expect(boolValue(store.object(forKey: "flag")) == true)
      #expect((store.object(forKey: "volume") as? Double) == 0.5)
      #expect((store.object(forKey: "device") as? String) == "uid")
      #expect(store.object(forKey: "nested") != nil)
    }
  }

  @Test func nilRemovesTheKey() throws {
    try withStore { store, defaults in
      store.set(1, forKey: "k")
      store.set(nil, forKey: "k")
      #expect(store.object(forKey: "k") == nil)
      #expect(defaults.object(forKey: "k") == nil)
    }
  }

  @Test func missingKeyIsNil() throws {
    try withStore { store, _ in #expect(store.object(forKey: "absent") == nil) }
  }

  @Test func rejectsNonPropertyListValuesWithoutCrashing() throws {
    try withStore { store, defaults in
      store.set(NSObject(), forKey: "object")
      store.set(Double.nan, forKey: "nan")
      store.set(Double.infinity, forKey: "inf")
      store.set([1: "x"] as [Int: Any], forKey: "intKeys")
      store.set([NSObject()], forKey: "array")
      for key in ["object", "nan", "inf", "intKeys", "array"] {
        #expect(defaults.object(forKey: key) == nil, "\(key) must not be stored")
      }
    }
  }

  @Test func rejectsTooDeepNesting() throws {
    try withStore { store, defaults in
      var value: Any = 1
      for _ in 0..<(UserDefaultsPreferencesStore.maxDepth + 2) { value = [value] }
      store.set(value, forKey: "deep")
      #expect(defaults.object(forKey: "deep") == nil)
    }
  }

  @Test func rejectsInvalidKeys() throws {
    try withStore { store, defaults in
      store.set(1, forKey: "")
      let long = String(repeating: "k", count: UserDefaultsPreferencesStore.maxKeyLength + 1)
      store.set(1, forKey: long)
      #expect(store.object(forKey: "") == nil)
      #expect(store.object(forKey: long) == nil)
      #expect(defaults.object(forKey: long) == nil)
    }
  }

  @Test func readsHostileExistingValuesAsIs() throws {
    try withStore { store, defaults in
      defaults.set(String(repeating: "x", count: 100_000), forKey: "big")
      defaults.set(Data([0xFF, 0x00]), forKey: "data")
      #expect((store.object(forKey: "big") as? String)?.count == 100_000)
      #expect(store.object(forKey: "data") is Data)
    }
  }

  private func boolValue(_ value: Any?) -> Bool? {
    (value as? NSNumber)?.boolValue
  }
}
