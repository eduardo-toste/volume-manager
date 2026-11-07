import Synchronization

@testable import VolumeCore

/// A clock that only moves when the test calls `advance(by:)`.
final class FakeClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now: Duration = .zero
    var nextID = 0
    var sleepers: [Int: Sleeper] = [:]
  }

  private let state = Mutex(State())

  var now: Instant { Instant(offset: state.withLock { $0.now }) }
  var minimumResolution: Duration { .zero }

  /// Number of tasks currently waiting on this clock.
  var sleeperCount: Int { state.withLock { $0.sleepers.count } }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let immediate = state.withLock { state -> Bool in
          if deadline.offset <= state.now { return true }
          state.sleepers[id] = Sleeper(deadline: deadline.offset, continuation: continuation)
          return false
        }
        if immediate {
          continuation.resume()
        } else if Task.isCancelled {
          cancel(id)
        }
      }
    } onCancel: {
      cancel(id)
    }
  }

  /// Moves time forward and wakes every sleeper whose deadline has passed.
  func advance(by duration: Duration) {
    let due = state.withLock { state -> [Sleeper] in
      state.now += duration
      let ids = state.sleepers.filter { $0.value.deadline <= state.now }.keys
      return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
    }
    for sleeper in due { sleeper.continuation.resume() }
  }

  private func cancel(_ id: Int) {
    let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
    sleeper?.continuation.resume(throwing: CancellationError())
  }
}

/// Lets queued tasks run until `condition` holds (or gives up after many turns).
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
  for _ in 0..<2000 {
    if condition() { return true }
    await Task.yield()
  }
  return condition()
}
