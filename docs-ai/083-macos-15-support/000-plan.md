# 083 — macOS 15 Support: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-10-19 |
| **Primary PRs** | — |
| **Related** | [061-native-toolbar-controls](../061-native-toolbar-controls/toolbar-controls.md), [044-foundation-model-branch-names](../044-foundation-model-branch-names/000-plan.md), [017-upstream-sync-process](../017-upstream-sync-process/upstream-ledger.md) |

## Background

Upstream Prowl is macOS 26 only: `App/Config/App.xcconfig` set
`MACOSX_DEPLOYMENT_TARGET = 26.0`, the UI is built on Liquid Glass (`glassEffect`,
`ToolbarSpacer`, `sharedBackgroundVisibility`, `toolbar(removing:)`), and branch-name
suggestions use Foundation Models. Upstream CI builds on an `xcode-27` runner
(`.github/workflows/test.yml`), so `.package.resolved` also contains releases whose
manifests declare `swift-tools-version: 6.4` (the pointfree stack, `xctest-dynamic-overlay`
via transitive requirements).

This fork is maintained on a Mac running macOS 15.7.2 and Xcode 16.4 (Swift 6.1, macOS 15.5
SDK). It cannot run an Xcode 27 build at all, and Apple's support matrix stops macOS-15
support at Xcode 26.3: Xcode 26.0–26.3 run on macOS Sequoia 15.6 or later, while Xcode 26.4
and later require macOS Tahoe 26. The fork therefore needs a macOS 15 deployment target, a
dependency set Swift 6.1 can build, and source that compiles both with the macOS 15 SDK and,
when one is available, with the macOS 26 SDK.

## Goals

- The app deploys to macOS 15.0 and runs there with every feature reachable.
- It builds and tests with Xcode 16.4 (Swift 6.1, macOS 15.5 SDK) — the toolchain on the
  fork's only machine — and still builds with Xcode 26+.
- Built with a macOS 26 SDK, the binary keeps Liquid Glass and Foundation Models on
  macOS 26 instead of compiling them out.
- One source tree: no `#if os` fork of the feature set, no second scheme.

**Non-goals**

- Keeping upstream's exact dependency versions. They require Swift 6.4 / Xcode 27, so the
  fork pins older releases (see below) until its toolchain floor moves.
- Running on Xcode 16.3 or earlier (Swift 6.0): the app uses Swift 6.1 language features
  (`isolated deinit` fallbacks excepted) and the `MemberImportVisibility` upcoming feature.
- Pixel-identical toolbar rendering on macOS 15. macOS 15 has no shared toolbar glass to
  reproduce, so the fallback is the platform's native per-item toolbar.
- macOS 14 or earlier.

## Design / Approach

### 1. Deployment target

`App/Config/App.xcconfig`, `App/Config/Project.xcconfig`, and `App/Config/Tests.xcconfig`
move to `MACOSX_DEPLOYMENT_TARGET = 15.0`. `Mirror/iOS` keeps its iOS 18.0 floor.

### 2. One home for macOS 26-only view APIs

`App/Sources/Support/LiquidGlassSupport.swift` owns every macOS 26 SwiftUI surface:

| Helper | macOS 26 | macOS 15 / older SDK |
| --- | --- | --- |
| `prowlGlass(_:interactive:)` | `glassEffect(_:in:)` | `background(.regularMaterial, in:)` |
| `ToolbarGroupSpacer` | `ToolbarSpacer(.fixed)` | empty `ToolbarItem` |
| `prowlHidingSharedBackground()` | `sharedBackgroundVisibility(.hidden)` | no-op (items draw their own background) |
| `prowlRemovingToolbarTitle()` | `toolbar(removing: .title)` | `NSWindow.titleVisibility = .hidden` |
| `worktreeDragSessionUpdates(_:)` / `sidebarDragSessionEnded(_:)` | `onDragSessionUpdated` | `SidebarDragEndMonitor` (mouse-up) |
| `GhosttySearchOverlayShape.path(in:)` (inline, same file) | `ConcentricRectangle` | `RoundedRectangle(cornerRadius: 8)` |

Each helper gates twice: `#if PROWL_LIQUID_GLASS` because an older SDK does not declare the
symbols at all (`@available` cannot rescue a missing symbol), and `#available(macOS 26.0, *)`
because a binary built against the macOS 26 SDK must not call them on macOS 15. The pairing
matters in both directions: a fallback that is only compiled under `#if !PROWL_LIQUID_GLASS`
disappears from an SDK-26 build, which still runs on macOS 15, so such a fallback has to be
reached through a runtime `#available` check instead.

`PROWL_LIQUID_GLASS` is a compilation condition defined by the SDK that is actually selected
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx2*]` in `App/Config/App.xcconfig`). A
compiler-version check would be wrong twice over: Swift 6.1 cannot see the symbols, and a
Swift 6.2+ compiler also builds against the macOS 15 SDK.

### 3. Foundation Models

`FoundationModelLLMService` imports the framework behind `canImport` and guards every call
with `@available(macOS 26.0, *)`; without it, `isAvailable` is `false` and branch names keep
the random adjective-animal fallback. Because the app deploys to macOS 15, the framework must
be weak-linked for SDKs that have it, and Swift must not add a strong autolink in the same
build:

- `PROWL_WEAK_FRAMEWORKS[sdk=macosx2*] = -weak_framework FoundationModels` (older SDKs have no
  such framework and would fail to link).
- `-Xfrontend -disable-autolink-framework -Xfrontend FoundationModels` in `OTHER_SWIFT_FLAGS`.

### 4. Dependencies pinned to Swift 6.1

The newest pointfree releases declare `swift-tools-version: 6.4`; Swift 6.1 refuses them, and
a `from:` requirement would re-resolve them. `App/Project.swift` therefore pins exact
versions, transitive packages included, at the newest release whose manifest works with
Swift 6.1:

| Package | Pin |
| --- | --- |
| swift-composable-architecture | 1.26.1 |
| swift-dependencies | 1.17.0 |
| swift-sharing | 2.9.1 |
| swift-perception | 2.0.11 |
| swift-navigation | 2.8.0 |
| swift-custom-dump | 1.7.0 |
| swift-clocks / combine-schedulers | 1.1.0 / 1.2.0 |
| swift-collections | 1.2.1 |
| swift-concurrency-extras | 1.4.3 |
| swift-syntax | 601.0.0 |
| xctest-dynamic-overlay | 1.11.0 |

`Shared`, `CLI`, and `Mirror/Relay` lower their own `swift-tools-version` to 6.1 for the same
reason, and `CLI/Package.swift` pins its dependencies (`swift-argument-parser` 1.7.1,
`swift-json-schema` 0.13.1, `Rainbow` 4.2.1, `Yams` 6.2.2, `swift-syntax` 601.0.0,
`swift-collections` 1.2.1).

### 5. Vendored GlyphonKit

Upstream GlyphonKit 0.1.0 declares `platforms: [.macOS(.v26)]` and imports FoundationModels
unconditionally; SwiftPM rejects that for a macOS 15 app, regardless of Xcode version.
`ThirdParty/GlyphonKit` is a vendored copy with three changes (see its `PATCHES.md`): platform
minimums lowered, the model pipeline behind `canImport` + `@available`, and no strong
FoundationModels autolink. Without the model it returns the retrieval-only result it already
produced when the model was unavailable.

### 6. Swift 6.1 isolation

Upstream builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Xcode 26). Swift 6.1 has no
default isolation and no isolated conformances, so every implicit main-actor assumption the
app relied on becomes explicit, in the smallest form that keeps the upstream shape:

- AppKit/UserNotifications protocol requirements that the macOS 15.5 SDK declares
  nonisolated get `@preconcurrency` conformances (`NSTextInputClient`,
  `NSServicesMenuRequestor`, `NSPopoverDelegate`, `UNUserNotificationCenterDelegate`) or a
  `nonisolated` override that hops with `MainActor.assumeIsolated`.
- Reducers and other nonisolated code that reads main-actor client dependencies wrap the call
  in `MainActor.assumeIsolated`, and `WorkflowRunsFeature`'s async effect `perform` is
  `@MainActor` so it matches upstream's main-actor effect work.
- `isolated deinit` is not used at all. An isolated deinit runs through the back-deployed
  `swift_task_deinitOnExecutor` on macOS 15, which corrupts task-local storage when the object is
  released inside a task-local scope — TCA's `withDependencies` makes every action such a scope —
  and aborts in `libmalloc` (swiftlang/swift#85204, #88036; it crashed the Canvas viewport
  animator when the Shelf replaced the Canvas). Every owner now has a non-isolated deinit that
  either runs the cleanup inline (state marked `nonisolated(unsafe)`) or wraps it in
  `MainActor.assumeIsolated` for objects AppKit releases on the main thread, spelled
  `nonisolated deinit` under Swift 6.2 and `deinit` under Swift 6.1.
- `Animatable.animatableData` stays nonisolated with `nonisolated(unsafe)` animated storage,
  which SwiftUI only touches on the main actor.
- Pure helpers that tests call off the main actor (path math, bucket math) are `nonisolated`.

### 7. macOS 15 portability fixes

Running the app and its tests on macOS 15 surfaced real differences, not just isolation:

- `URL.path(percentEncoded:)` appends a trailing slash for an existing directory on macOS 15
  and does not on macOS 26. `GitClient.canonicalWorktreePath` now strips it, so the same
  worktree compares equal before and after its directory moves (this broke the
  locked-worktree removal fallback).
- `posix_spawn_file_actions_addchdir` is macOS 26 only; `RemoteCommandRunner` uses the
  `_np` spelling available since macOS 10.15.
- `ConcentricRectangle`, `onDragSessionUpdated`, `Button(LocalizedStringResource)`, and
  `Observations` are macOS 26 APIs; the app and tests have fallbacks (rounded rect, mouse-up
  monitor, `Text`-labelled button, polling test shim).

## Alternatives & decisions

| Option | Why not |
| --- | --- |
| Stay on macOS 26 and require macOS 26 hardware | The fork's only machine runs macOS 15.7.2 and cannot install Xcode 27. |
| Require Xcode 26.3 only | It works, but the machine has Xcode 16.4 and installing 26.3 is a 12 GB download the fork cannot do headlessly; the fork should build on what is installed. |
| Keep upstream's package pins and build with Xcode 27 | Not runnable on macOS 15. |
| Compile Foundation Models out entirely | Loses branch-name suggestions on macOS 26; the weak link keeps them. |
| Load FoundationModels dynamically (`dlopen`) | Swift-native async API cannot be reached through `dlsym` without reimplementing bindings. |
| `#if compiler(>=6.2)` instead of `#if PROWL_LIQUID_GLASS` | A Swift 6.2 compiler also builds against the macOS 15 SDK, where the symbols do not exist. |
| `#if compiler(>=6.2)` only, no `@available` | A macOS 26 SDK build would then call Liquid Glass on macOS 15 at runtime. |

## Amendments

- **Path-derived identifiers (2026-10-19).** §7's trailing-slash fix covered worktree paths only.
  Repository ids, workspace-child ids, and the ids restored from the repository snapshot cache
  are path-derived too, and `URL.path(percentEncoded:)` appends "/" for an existing directory on
  macOS 15, so those ids differed from the canonical worktree ids and were OS-dependent. All of
  them now go through `PathPolicy.trimmingTrailingSlash`, which `PathPolicy.normalizePath` applies
  as well, so one directory always renders as one string.
- **SDK conditions (2026-10-19).** `sdk=macosx2*` covers the macOS 20–29 SDKs, not "every later
  SDK"; an SDK named `macosx30` needs its own condition or the app links FoundationModels
  strongly again and loses Liquid Glass. Recorded in `App/Config/App.xcconfig`.
