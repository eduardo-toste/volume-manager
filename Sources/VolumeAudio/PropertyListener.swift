import CoreAudio
import Dispatch
import Synchronization

/// A registered Core Audio property listener, removed when this object is released (RAII).
/// The handler runs on `queue`, never on the audio thread.
final class PropertyListener: Sendable {
  private struct Registration {
    let object: AudioObjectID
    let addresses: [AudioObjectPropertyAddress]
    let queue: DispatchQueue
    /// Kept as the very same block object that was registered: removal needs identity.
    let block: AudioObjectPropertyListenerBlock
  }

  private let registration: Mutex<Registration?>

  /// Registers `handler` for every address; removes what it registered if any fails.
  init(
    object: AudioObjectID, addresses: [AudioObjectPropertyAddress], queue: DispatchQueue,
    handler: @escaping @Sendable () -> Void
  ) throws(AudioError) {
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    var added: [AudioObjectPropertyAddress] = []
    for address in addresses {
      var copy = address
      let status = AudioObjectAddPropertyListenerBlock(object, &copy, queue, block)
      if status != noErr {
        for done in added {
          var undo = done
          _ = AudioObjectRemovePropertyListenerBlock(object, &undo, queue, block)
        }
        throw AudioError(
          status: status,
          context: "add listener for \(AudioProperty.describe(address)) of object \(object)")
      }
      added.append(address)
    }
    registration = Mutex(
      Registration(object: object, addresses: addresses, queue: queue, block: block))
  }

  /// Removes the listener now. Safe to call more than once.
  func cancel() {
    let current = registration.withLock { state -> Registration? in
      defer { state = nil }
      return state
    }
    guard let current else { return }
    for address in current.addresses {
      var copy = address
      _ = AudioObjectRemovePropertyListenerBlock(
        current.object, &copy, current.queue, current.block)
    }
  }

  deinit { cancel() }
}
