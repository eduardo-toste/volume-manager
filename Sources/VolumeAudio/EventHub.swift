import Synchronization

/// Delivers each event to every subscriber. Thread safe; used for streams that Core Audio
/// callbacks, actors and tests all feed or read.
final class EventHub<Event: Sendable>: Sendable {
  private struct State {
    var nextID = 0
    var continuations: [Int: AsyncStream<Event>.Continuation] = [:]
  }

  private let state = Mutex(State())

  /// A new independent stream. It stops receiving events when the consumer is done with it.
  func makeStream(
    bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<Event> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Event.self, bufferingPolicy: bufferingPolicy)
    let id = state.withLock { state -> Int in
      state.nextID += 1
      state.continuations[state.nextID] = continuation
      return state.nextID
    }
    continuation.onTermination = { [weak self] _ in
      self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  /// Sends `event` to every subscriber.
  func yield(_ event: Event) {
    let all = state.withLock { Array($0.continuations.values) }
    for continuation in all { continuation.yield(event) }
  }

  /// Ends every stream.
  func finishAll() {
    let all = state.withLock { state -> [AsyncStream<Event>.Continuation] in
      let values = Array(state.continuations.values)
      state.continuations.removeAll()
      return values
    }
    for continuation in all { continuation.finish() }
  }

  /// Number of live subscribers.
  var subscriberCount: Int { state.withLock { $0.continuations.count } }

  deinit { finishAll() }
}
