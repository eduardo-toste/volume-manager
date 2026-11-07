import Synchronization

/// A counter that queued work reads to learn that it became obsolete (for example, after the
/// panic button discarded pending reconciliations).
final class EpochCounter: Sendable {
  private let value = Mutex(0)

  /// The current generation.
  var current: Int { value.withLock { $0 } }

  /// Starts a new generation and returns it.
  @discardableResult
  func advance() -> Int {
    value.withLock { count in
      count += 1
      return count
    }
  }
}
