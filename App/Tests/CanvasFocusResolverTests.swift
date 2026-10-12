import Foundation
import Testing

@testable import Prowl

struct CanvasFocusResolverTests {
  @Test func worktreeTargetSelectsFirstCardWhenNothingIsFocused() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasCardRef(worktreeID: worktreeID, tabID: first),
        CanvasCardRef(worktreeID: worktreeID, tabID: second),
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == first)
  }

  @Test func worktreeTargetCyclesFromFocusedCardToNextMatch() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())
    let other = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasCardRef(worktreeID: worktreeID, tabID: first),
        CanvasCardRef(worktreeID: "/tmp/other/main", tabID: other),
        CanvasCardRef(worktreeID: worktreeID, tabID: second),
      ],
      currentPrimaryTabID: first
    )

    #expect(resolved == second)
  }

  @Test func worktreeTargetWrapsFromLastFocusedCardToFirstMatch() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasCardRef(worktreeID: worktreeID, tabID: first),
        CanvasCardRef(worktreeID: worktreeID, tabID: second),
      ],
      currentPrimaryTabID: second
    )

    #expect(resolved == first)
  }

  @Test func tabTargetSelectsExactVisibleCard() {
    let requested = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .tab(requested)),
      candidates: [
        CanvasCardRef(worktreeID: "/tmp/repo/main", tabID: TerminalTabID(rawValue: UUID())),
        CanvasCardRef(worktreeID: "/tmp/repo/main", tabID: requested),
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == requested)
  }

  @Test func tabTargetWaitsWhenExactCardIsNotVisibleYet() {
    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .tab(TerminalTabID(rawValue: UUID()))),
      candidates: [
        CanvasCardRef(worktreeID: "/tmp/repo/main", tabID: TerminalTabID(rawValue: UUID()))
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == nil)
  }
}
