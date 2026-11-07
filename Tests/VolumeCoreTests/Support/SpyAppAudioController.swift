import Synchronization

@testable import VolumeCore

/// Records what the domain asks the audio controller to do.
final class SpyAppAudioController: AppAudioController, Sendable {
  enum Call: Sendable, Equatable {
    case reconcile([DesiredAppAudio])
    case restoreAll
  }

  private let recorded = Mutex<[Call]>([])

  var calls: [Call] { recorded.withLock { $0 } }

  var reconcileCalls: [[DesiredAppAudio]] {
    calls.compactMap { call in
      if case .reconcile(let desired) = call { return desired }
      return nil
    }
  }

  /// True when every reconcile call so far asked for no tap at all.
  var neverTapped: Bool { reconcileCalls.allSatisfy { $0.isEmpty } }

  var restoreAllCount: Int { calls.filter { $0 == .restoreAll }.count }

  func reconcile(desired: [DesiredAppAudio]) async {
    recorded.withLock { $0.append(.reconcile(desired)) }
  }

  func restoreAll() async {
    recorded.withLock { $0.append(.restoreAll) }
  }
}
