import Synchronization

@testable import VolumeCore

/// Records what the domain asks the audio controller to do.
final class SpyAppAudioController: AppAudioController, Sendable {
  enum Call: Sendable, Equatable {
    case reconcile([DesiredAppAudio])
    case restoreAll
    case retry(String)
    case retryAll
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

  func retry(appID: String) async {
    recorded.withLock { $0.append(.retry(appID)) }
  }

  func retryAll() async {
    recorded.withLock { $0.append(.retryAll) }
  }
}
