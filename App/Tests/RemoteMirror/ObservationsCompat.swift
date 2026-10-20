import Testing

/// Polls a main-actor value so `for await value in ... where condition` works on toolchains that
/// predate Swift 6.2's `Observations`. Every mirror test waits on state that the host or client
/// mutates on the main actor, so a short poll is enough and keeps the call sites uniform.
nonisolated struct ObservationsCompat<Value: Sendable>: AsyncSequence {
  private let read: @MainActor @Sendable () -> Value
  private let timeout: Duration

  init(timeout: Duration = .seconds(10), _ read: @escaping @MainActor @Sendable () -> Value) {
    self.timeout = timeout
    self.read = read
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let read: @MainActor @Sendable () -> Value
    let deadline: ContinuousClock.Instant

    mutating func next() async -> Value? {
      guard ContinuousClock.now < deadline else { return nil }
      let value = await MainActor.run { read() }
      try? await Task.sleep(for: .milliseconds(5))
      return value
    }
  }

  nonisolated func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(read: read, deadline: ContinuousClock.now.advanced(by: timeout))
  }
}
