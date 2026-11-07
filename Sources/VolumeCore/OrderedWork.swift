/// Runs asynchronous operations one after another, in the order they were queued, without
/// blocking the caller. Keeps service calls from overtaking each other.
@MainActor
final class OrderedWork {
  private var last: Task<Void, Never>?

  /// Queues `operation` after everything queued before.
  func enqueue(_ operation: @escaping @Sendable () async -> Void) {
    let previous = last
    last = Task {
      await previous?.value
      await operation()
    }
  }

  /// Returns when everything queued so far has finished.
  func settle() async {
    await last?.value
  }
}
