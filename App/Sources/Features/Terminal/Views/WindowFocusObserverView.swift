import AppKit
import SwiftUI

struct WindowActivityState: Equatable {
  let isKeyWindow: Bool
  let isVisible: Bool

  static let inactive = Self(isKeyWindow: false, isVisible: false)
}

struct WindowFocusObserverView: NSViewRepresentable {
  let onWindowActivityChanged: (WindowActivityState) -> Void

  func makeNSView(context: Context) -> WindowFocusObserverNSView {
    let view = WindowFocusObserverNSView()
    view.onWindowActivityChanged = onWindowActivityChanged
    return view
  }

  func updateNSView(_ nsView: WindowFocusObserverNSView, context: Context) {
    nsView.onWindowActivityChanged = onWindowActivityChanged
  }
}

final class WindowFocusObserverNSView: NSView {
  var onWindowActivityChanged: (WindowActivityState) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []
  private weak var observedWindow: NSWindow?
  private var lastEmittedActivity: WindowActivityState?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateObservers()
  }

  private var activityState: WindowActivityState {
    guard let window else { return .inactive }
    return WindowActivityState(
      isKeyWindow: window.isKeyWindow,
      isVisible: window.occlusionState.contains(.visible)
    )
  }

  private func updateObservers() {
    if observedWindow === window {
      emitActivityIfNeeded()
      return
    }
    clearObservers()
    observedWindow = window
    guard let window else {
      // View is being torn down from its window (e.g. a sibling view
      // swap in SwiftUI). The window itself is not going away — other
      // observers watching the same `WorktreeTerminalState` are still
      // live and reflect the real window activity. Emitting an
      // inactive signal here would poison the shared state's
      // `lastWindowIsKey`/`lastWindowIsVisible`, causing
      // `applySurfaceActivity` to demote focus even though the window
      // is still key. Just stop observing silently and let the
      // surviving observer drive state. This branch is covered by
      // `WindowFocusObserverViewTests.detachFromWindowEmitsNothingNew`.
      return
    }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded()
        }
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded()
        }
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded()
        }
      })
    emitActivityIfNeeded(force: true)
  }

  private func emitActivityIfNeeded(force: Bool = false) {
    let activity = activityState
    if !force, activity == lastEmittedActivity {
      return
    }
    lastEmittedActivity = activity
    onWindowActivityChanged(activity)
  }

  private func clearObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  // A non-isolated deinit keeps teardown off the back-deployed `swift_task_deinitOnExecutor`
  // that an isolated deinit uses on macOS 15 and that corrupts task-local storage when the
  // release runs inside a task-local scope (swiftlang/swift#85204, #88036).
  // AppKit releases this view on the main thread.
  #if compiler(>=6.2)
    nonisolated deinit {
      MainActor.assumeIsolated { clearObservers() }
    }
  #else
    deinit {
      MainActor.assumeIsolated { clearObservers() }
    }
  #endif
}
