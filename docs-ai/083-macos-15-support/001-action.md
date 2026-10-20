# 083 — macOS 15 Support: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-19 | Deployment target to 15.0, SDK-gated Liquid Glass helpers, weak-linked Foundation Models | `382c51c` |
| 2026-10-19 | Swift 6.1 build support: exact package pins, vendored GlyphonKit, explicit isolation, macOS 15 portability fixes, test adjustments | `a4a1d2c` + the follow-up commit below |
| 2026-10-19 | Toolchain moved to Xcode 26.3 / macOS 26.2 SDK (Swift 6.2.4); macOS 26 branches now compile, weak link and macOS 15 runtime verified, app tests green | this commit |
| 2026-10-19 | Review round: `make format-changed` actually formats every changed file, the macOS 15 drag-end fallback runs on a runtime availability check, one Sparkle updater per process, path-derived ids canonicalized through `PathPolicy` | this commit |

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
  parallel: **4106 passed, 0 failed of 4112**. The six mirror/event-monitor/shell-cancellation
  tests that the Makefile runs separately also pass on Xcode 26.3, so the whole app suite is
  green.
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

## Review corrections (2026-10-19)

A read-through of the branch before publishing found six defects; all are fixed here.

- `make format-changed` piped the newline-joined file list into `printf '%s\0'` as one argument,
  so with two or more changed files `xargs -0` handed `swift-format` a single nonexistent path and
  the target silently formatted nothing — the failure it was written to fix, in a new shape. It now
  converts the list to NUL separators with `tr` and reports the file count.
- `SidebarDragEndMonitor` was armed under `#if !PROWL_LIQUID_GLASS`, which is an SDK check, while
  the macOS 26 path uses a runtime `#available`. On an SDK-26 build running on macOS 15 neither
  path ran, so the drag state it exists to clear was never cleared. It now returns early when
  `onDragSessionUpdated` exists at runtime, and a deferred mouse-up handler from an earlier drag can
  no longer clear a later drag's state (generation guard).
- `UpdaterClient.liveValue` became a computed `static var` that starts an `SPUUpdater` on every
  resolution; only swift-dependencies' per-lineage cache kept a second updater from being created
  with a second (event-less) user driver. The updater is now built once, on main.
- Repository ids, workspace-child ids, and snapshot-restored ids still used raw
  `path(percentEncoded:)`, so on macOS 15 they carried the trailing slash Foundation appends while
  worktree ids did not — and the ids are persisted keys. Everything path-derived now goes through
  `PathPolicy.trimmingTrailingSlash`, which `PathPolicy.normalizePath` also applies.
- `MainActor.assumeIsolated` was wrapped around plain `@Sendable` client closures
  (`CLIInstallClient.installationStatus`/`isUsable`), where it only adds a trap; those calls are
  direct again. The remaining uses all reach genuinely main-actor-bound clients.
- `App.xcconfig` claimed `sdk=macosx2*` covers "every 20-and-later SDK"; it covers macOS 20–29.
  Recorded, together with the `Project.swift` and command-palette comments that described the
  toolchain and the type-checker workaround inaccurately.

## Open questions

- The macOS 26 branches compile and link, but only the macOS 15 *runtime* was exercised here
  (that is what this machine runs). The Liquid Glass rendering itself and the on-device
  branch-name model still need a macOS 26 machine to look at.
- `make test-all`'s iOS and Android mirror suites and the zig-built GhosttyKit path were not
  run in this environment.
