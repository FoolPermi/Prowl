import Foundation

/// Coalesces bursts of calls into a single delayed action: each `schedule`
/// replaces the pending action and restarts the interval, and a cancelled
/// action never fires.
///
/// Centralizes the two easy-to-miss parts of the hand-rolled pattern: catching
/// the sleep's `CancellationError` *and* re-checking `Task.isCancelled` once
/// the sleep resumes, so a cancelled task can't slip through and run anyway.
@MainActor
final class Debouncer {
  private let interval: Duration
  private let clock: any Clock<Duration>
  private var task: Task<Void, Never>?

  init(interval: Duration, clock: any Clock<Duration> = ContinuousClock()) {
    self.interval = interval
    self.clock = clock
  }

  /// True when no action is pending, i.e. the next `schedule` starts a fresh
  /// debounce window. Callers implementing leading-edge behavior check this to
  /// decide whether to act immediately instead.
  var isIdle: Bool { task == nil }

  /// Schedules `action` to run after the interval, replacing any pending action.
  func schedule(_ action: @escaping @MainActor () async -> Void) {
    task?.cancel()
    let sleep = clock.anchoredSleep(for: interval)
    task = Task {
      do {
        try await sleep()
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self.task = nil
      await action()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

/// Captures the debounce deadline synchronously at `schedule` time instead of
/// when the spawned task first runs. Under scheduler load the task can start
/// measurably late, which would silently stretch the window — and, with a
/// `TestClock`, let the test advance past a deadline that was never armed,
/// hanging the sleep forever (the CI-only `DebouncerTests` flake).
extension Clock where Duration == Swift.Duration {
  func anchoredSleep(for interval: Duration) -> @Sendable () async throws -> Void {
    let deadline = now.advanced(by: interval)
    return { try await self.sleep(until: deadline, tolerance: nil) }
  }
}

/// A `Debouncer` variant that maintains an independent debounce window per key,
/// for stores that coalesce events per worktree, repository, or host.
@MainActor
final class KeyedDebouncer<Key: Hashable & Sendable> {
  private let interval: Duration
  private let clock: any Clock<Duration>
  private var tasks: [Key: Task<Void, Never>] = [:]

  init(interval: Duration, clock: any Clock<Duration> = ContinuousClock()) {
    self.interval = interval
    self.clock = clock
  }

  // `KeyedDebouncer` is generic, so its deinit is synthesized — and under `-default-isolation MainActor`
  // that synthesized deinit is isolated, which is the one shape the 083 sweep could not see: it looked
  // for explicit `deinit`s, and this class has none. An isolated deinit also runs through the
  // back-deployed `swift_task_deinitOnExecutor` on macOS 15 (docs-ai 083), and Swift 6.2.4's optimizer
  // crashes outright on it in a Release build (EarlyPerfInliner, `KeyedDebouncerCfD`,
  // swiftlang/swift#88173). An explicit non-isolated deinit keeps teardown off that path; its empty body
  // changes nothing else, because the synthesized deinit only released the stored properties. The pending
  // tasks hold `self` strongly, so none of them can still be running here.
  #if compiler(>=6.2)
    nonisolated deinit {}
  #else
    deinit {}
  #endif

  /// Schedules `action` for `key` after `interval` (defaulting to the instance
  /// interval), replacing any action already pending for the same key.
  func schedule(_ key: Key, after interval: Duration? = nil, _ action: @escaping @MainActor () async -> Void) {
    tasks[key]?.cancel()
    let sleep = clock.anchoredSleep(for: interval ?? self.interval)
    tasks[key] = Task {
      do {
        try await sleep()
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self.tasks.removeValue(forKey: key)
      await action()
    }
  }

  func cancel(_ key: Key) {
    tasks.removeValue(forKey: key)?.cancel()
  }

  /// Cancels every pending action, or only those whose key matches `shouldCancel`.
  func cancelAll(where shouldCancel: (Key) -> Bool = { _ in true }) {
    for key in Array(tasks.keys) where shouldCancel(key) {
      tasks.removeValue(forKey: key)?.cancel()
    }
  }
}
