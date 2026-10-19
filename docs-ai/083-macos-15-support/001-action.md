# 083 — macOS 15 Support: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-19 | Deployment target to 15.0, SDK-gated Liquid Glass helpers, weak-linked Foundation Models | `382c51c` |
| 2026-10-19 | Swift 6.1 build support: exact package pins, vendored GlyphonKit, explicit isolation, macOS 15 portability fixes, test adjustments | `a4a1d2c` + the follow-up commit below |
| 2026-10-19 | Toolchain moved to Xcode 26.3 / macOS 26.2 SDK (Swift 6.2.4); macOS 26 branches now compile, weak link and macOS 15 runtime verified, app tests green | this commit |

## Outcome & current state (as of 2026-10-19)

`App/Project.swift` and the three app xcconfigs now describe one configuration that builds
with Swift 6.1 and keeps the macOS 26 features:

- **SDK gate.** `App/Config/App.xcconfig` defines `PROWL_LIQUID_GLASS` for
  `sdk=macosx2*`, so `App/Sources/Support/LiquidGlassSupport.swift` compiles the Liquid Glass
  branches only when the selected SDK has those symbols. On the macOS 15.5 SDK
  `xcodebuild -showBuildSettings` reports `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` and no
  `-weak_framework FoundationModels`; on the macOS 26.2 SDK it reports the condition and the
  weak framework, and the built app carries `LC_LOAD_WEAK_DYLIB` for FoundationModels.
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

- App build: `xcodebuild build` with both Xcode 16.4 / macOS 15.5 SDK and Xcode 26.3 /
  macOS 26.2 SDK, target macOS 15.0 — `BUILD SUCCEEDED` in both, with the macOS 26 branches
  compiled in the latter and `PROWL_LIQUID_GLASS` defined.
- Building against the macOS 26 SDK needed six fixes that do not exist on the 15.5 SDK:
  `@available(macOS 26.0, iOS 26.0, *)` on GlyphonKit's `@Generable`/`@Guide` pipeline and its
  model functions, explicit `return` in `AIAvailability.current`, `nonisolated` on
  `BundledCLILocator.url` under default MainActor isolation, inlined cleanup in the
  `isolated deinit` branches, and runtime `#available` guards around `ConcentricRectangle` and
  `onDragSessionUpdated` (they are 26-only at runtime too, not just at compile time).
- App run (macOS 15.7.2, Debug build from the macOS 26.2 SDK): `otool -l` shows
  FoundationModels as `LC_LOAD_WEAK_DYLIB`, and the app launches, opens `/tmp/prowl-e2e`, and its
  `prowl` CLI round-trips — `list`, `open`, `focus`, `create tab`, `canvas show/hide`,
  `agents`, `profiles list`, and `send --capture` (a shell printed `15.7.2`). No crash
  reports after the dependency-resolution fix.
- Tests, main partition in a copy of the checkout outside `~/Documents` (the app test host
  cannot read repository fixtures from `~/Documents` without a TCC grant), Xcode 26.3,
  parallel: **4106 passed, 0 failed of 4112** (six mirror/event-monitor/shell-cancellation
  tests belong to the Makefile's separate runs).
- `ShelfSpineMotionTests` was the last failure: on macOS 15 SwiftUI animates the spine's layer
  geometry without moving the hosted NSView's frame each frame, so sampling the frame saw only
  the endpoints. The test now samples the animated width value and keeps the final-frame and
  instant-chrome assertions.
- Parallel app tests work again on Xcode 26 (`swift-testing`'s "Test already started"
  assertion was a 6.1-era bug), so `APP_TEST_PARALLEL_ARGS` is empty by default again and only
  kept as a diagnostic switch.
- `make format-changed` was silently a no-op on macOS's bash 3.2 (`mapfile`); it now builds
  the file list with `printf`/`xargs -0`.
- `make check` passes end to end (format-changed, format-lint, swiftlint, script tests,
  workflow/legacy naming, string-catalog check) once the machine has Python 3.13 and
  swift-format 604 from Homebrew; the Makefile's `format-changed` no longer needs bash 4's
  `mapfile`, which macOS's `/bin/bash` lacks.

## Deviations from plan

- The plan listed "Xcode 16.4 / Swift 6.1" as a non-goal. The machine started on Xcode 16.4,
  so the implementation also supports Swift 6.1 (pins, tools versions, explicit isolation).
  Xcode 26.3 was installed later and now builds the macOS 26 branches; the 6.1 fallbacks stay
  for machines that still use an older Xcode.
- The plan's SDK gate was `#if compiler(>=6.2)`; it is `#if PROWL_LIQUID_GLASS` because a
  Swift 6.2 compiler also builds against the macOS 15 SDK.
- The plan did not anticipate the Foundation trailing-slash difference, the `_np` spawn
  symbol, the `UpdaterClient` dependency being resolved off the main actor, or the deinit
  access rules. All are recorded above.

## Open questions

- The macOS 26 branches compile and link, but only the macOS 15 *runtime* was exercised here
  (that is what this machine runs). The Liquid Glass rendering itself and the on-device
  branch-name model still need a macOS 26 machine to look at.
- `make test-all`'s iOS and Android mirror suites and the zig-built GhosttyKit path were not
  run in this environment.
