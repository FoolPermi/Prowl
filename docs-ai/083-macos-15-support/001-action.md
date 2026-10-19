# 083 — macOS 15 Support: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-19 | Deployment target to 15.0, SDK-gated Liquid Glass helpers, weak-linked Foundation Models | `382c51c` |
| 2026-10-19 | Swift 6.1 build support: exact package pins, vendored GlyphonKit, explicit isolation, macOS 15 portability fixes, test adjustments | `a4a1d2c` + the follow-up commit below |

## Outcome & current state (as of 2026-10-19)

`App/Project.swift` and the three app xcconfigs now describe one configuration that builds
with Swift 6.1 and keeps the macOS 26 features:

- **SDK gate.** `App/Config/App.xcconfig` defines `PROWL_LIQUID_GLASS` for
  `sdk=macosx2*`, so `App/Sources/Support/LiquidGlassSupport.swift` compiles the Liquid Glass
  branches only when the selected SDK has those symbols. `xcodebuild -showBuildSettings` on
  the macOS 15.5 SDK reports `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` and no
  `-weak_framework FoundationModels`, which is the intended older-SDK shape.
- **Dependency pins.** `App/Project.swift` pins the exact versions listed in
  `000-plan.md`; `.package.resolved` and `CLI/Package.resolved` were regenerated from them.
  `Shared`, `CLI`, and `Mirror/Relay` declare `swift-tools-version: 6.1`.
- **Vendored GlyphonKit.** `ThirdParty/GlyphonKit` (see `PATCHES.md`) replaces the upstream
  package reference; the model pipeline is behind `canImport` + `@available` and the module
  no longer autolinks FoundationModels strongly.
- **Explicit isolation.** `MainActor.assumeIsolated` around main-actor clients in reducers
  (safe because TCA's `Send` is `@MainActor`, so every action reaches the reducer on the main
  actor), `@MainActor` on `CommandHandler` and the async `WorkflowRunsFeature.perform`,
  `@preconcurrency` conformances for the AppKit/UserNotifications protocols whose requirements
  are nonisolated in the macOS 15 SDK, `nonisolated(unsafe)` for `Animatable` data and the
  deinit-only handles, and `#if compiler(>=6.2)` fallbacks for `isolated deinit`.
- **Portability fixes.** `GitClient.canonicalWorktreePath` and the `ProjectWorkspace` member
  paths drop the trailing slash macOS 15 appends to existing directories (this also makes
  worktree IDs clean, so `prowl focus /tmp/repo` resolves), `RemoteCommandRunner` uses
  `posix_spawn_file_actions_addchdir_np`, and `ConcentricRectangle`,
  `onDragSessionUpdated`, `Button(LocalizedStringResource)`, and `Observations` have
  fallbacks.
- **Test-side adaptations.** Suites that call main-actor statics are `@MainActor`; path and
  URL comparisons tolerate the trailing-slash difference; `ObservationsCompat` polls in the
  mirror tests; `CLIInstallClient` finds the bundled CLI through `Bundle.bundleURL` because
  `Bundle.resourceURL` is relative in the Swift Testing host.

## Verification performed

- App build: `xcodebuild build` with Xcode 16.4 / macOS 15.5 SDK, target macOS 15.0 —
  `BUILD SUCCEEDED`, no warnings promoted to errors.
- App run (macOS 15.7.2, Debug build): the app launches, opens `/tmp/prowl-e2e`, and its
  `prowl` CLI round-trips — `list`, `open`, `focus`, `create tab`, `canvas show/hide`,
  `agents`, `profiles list`, and `send --capture` (a shell printed `15.7.2`). No crash
  reports after the dependency-resolution fix.
- Tests, serial main partition in a copy of the checkout outside `~/Documents` (the app test
  host cannot read repository fixtures from `~/Documents` without a TCC grant):
  **4104 passed, 2 failed of 4112**. `AgentSessionDaemonResolutionTests` was killed by the
  system under memory pressure and passes in isolation; `ShelfSpineMotionTests` is the
  rendering-timing case below. The mirror suites and the event-monitor suites, which the
  Makefile runs separately, pass in their own run.
- A single parallel `xcodebuild test` over the whole target trips a `swift-testing` harness
  assertion ("Test already started") in this toolchain; the partitioned or serial runs pass,
  so `make test` now passes `-parallel-testing-enabled NO` (`APP_TEST_PARALLEL_ARGS`) to the
  four app test runs.
- `make format-changed` was silently a no-op on macOS's bash 3.2 (`mapfile`); it now builds
  the file list with `printf`/`xargs -0`.
- `make check` passes end to end (format-changed, format-lint, swiftlint, script tests,
  workflow/legacy naming, string-catalog check) once the machine has Python 3.13 and
  swift-format 604 from Homebrew; the Makefile's `format-changed` no longer needs bash 4's
  `mapfile`, which macOS's `/bin/bash` lacks.

## Deviations from plan

- The plan listed "Xcode 16.4 / Swift 6.1" as a non-goal. The machine only has Xcode 16.4, and
  installing Xcode 26.3 was not possible here, so the implementation also supports Swift 6.1
  (pins, tools versions, explicit isolation). The macOS 26 path is now source-compatible but
  was not compiled here.
- The plan's SDK gate was `#if compiler(>=6.2)`; it is `#if PROWL_LIQUID_GLASS` because a
  Swift 6.2 compiler also builds against the macOS 15 SDK.
- The plan did not anticipate the Foundation trailing-slash difference, the `_np` spawn
  symbol, the `UpdaterClient` dependency being resolved off the main actor, or the deinit
  access rules. All are recorded above.

## Open questions

- The macOS 26 SDK path (`PROWL_LIQUID_GLASS` branches, the weak FoundationModels link) has
  not been compiled or run; it needs an Xcode 26 machine. The weak-link build setting is
  deliberately written so a mistake fails at link time rather than at launch.
- `ShelfSpineMotionTests.bookMotionInterpolatesWhileSelectionChromeChangesImmediately` records
  only the animation endpoints on macOS 15 (an off-screen `NSHostingView` in a background
  window does not tick intermediate frames here). The app animates normally; the test needs a
  visible window or a display-driven clock to sample macOS 15.
- Running the whole app test target in one parallel `xcodebuild test` trips
  `swift-testing`'s "Test already started" harness assertion in this toolchain; the suites
  pass when run serially or in `make test`'s partitioned runs. The mirror suites and the
  event-monitor suites still need the Makefile's separate runs.
