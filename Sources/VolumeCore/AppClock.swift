/// The clock injected wherever the domain waits (debounce, the 15 s tap linger, the stable
/// session timer). Production uses `ContinuousClock`; tests use a fake they advance by hand.
public typealias AppClock = any Clock<Duration> & Sendable
