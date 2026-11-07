/// Key-value storage for preferences (backed by `UserDefaults` in production).
///
/// Values read back are untrusted: the user or another program may have edited them. Callers
/// validate everything (SPEC 12.9.4).
@MainActor
public protocol PreferencesStore {
  /// The stored value for `key`, of any type, or `nil`.
  func object(forKey key: String) -> Any?
  /// Stores `value`, or removes the key when `value` is `nil`.
  func set(_ value: Any?, forKey key: String)
}
