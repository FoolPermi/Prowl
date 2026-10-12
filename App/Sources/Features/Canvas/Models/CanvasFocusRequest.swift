import Foundation
import ProwlCLIShared

struct CanvasFocusRequest: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case worktree(Worktree.ID)
    case tab(TerminalTabID)
  }

  let id: Int
  let target: Target
}

/// One card on the canvas: an open tab that has a surface, plus the worktree
/// that owns it.
struct CanvasCardRef: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID

  var key: String { tabID.canvasCardKey }
}

extension TerminalTabID {
  /// Key of this tab's card in `CanvasLayoutStore` (persisted, so it must stay
  /// the tab UUID string).
  var canvasCardKey: String { rawValue.uuidString }
}

/// A reducer-driven request to run one of CanvasView's view-local commands
/// (which live in CanvasView's `@State`, not the reducer) — e.g. triggered from
/// the command palette. CanvasView observes it, runs the command, and reports
/// the id back to clear it (the same one-shot pattern as `CanvasFocusRequest`).
struct CanvasCommandRequest: Equatable, Sendable {
  enum Command: Equatable, Sendable {
    case toggleExpand
    case layout(CanvasLayoutKind)
    case selectAll
    case navigate(CanvasNavigationDirection)
  }

  let id: Int
  let command: Command
}

enum CanvasFocusResolver {
  static func resolve(
    request: CanvasFocusRequest,
    candidates: [CanvasCardRef],
    currentPrimaryTabID: TerminalTabID?
  ) -> TerminalTabID? {
    switch request.target {
    case .tab(let tabID):
      return candidates.contains { $0.tabID == tabID } ? tabID : nil

    case .worktree(let worktreeID):
      let matchingTabIDs = candidates.compactMap { candidate in
        candidate.worktreeID == worktreeID ? candidate.tabID : nil
      }
      guard !matchingTabIDs.isEmpty else { return nil }
      guard let currentPrimaryTabID,
        let currentIndex = matchingTabIDs.firstIndex(of: currentPrimaryTabID)
      else {
        return matchingTabIDs[0]
      }
      return matchingTabIDs[(currentIndex + 1) % matchingTabIDs.count]
    }
  }
}
