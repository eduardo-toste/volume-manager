/// A small least-recently-used cache with a fixed capacity.
struct LRUCache<Key: Hashable, Value> {
  private let capacity: Int
  private var values: [Key: Value] = [:]
  /// Keys from least to most recently used.
  private var order: [Key] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  var count: Int { values.count }

  /// The value for `key`, marking it as most recently used.
  mutating func value(for key: Key) -> Value? {
    guard let value = values[key] else { return nil }
    touch(key)
    return value
  }

  /// Stores `value`, evicting the least recently used entry when the cache is full.
  mutating func insert(_ value: Value, for key: Key) {
    if values[key] == nil, values.count >= capacity, let oldest = order.first {
      order.removeFirst()
      values[oldest] = nil
    }
    values[key] = value
    touch(key)
  }

  func contains(_ key: Key) -> Bool { values[key] != nil }

  private mutating func touch(_ key: Key) {
    if let index = order.firstIndex(of: key) { order.remove(at: index) }
    order.append(key)
  }
}
