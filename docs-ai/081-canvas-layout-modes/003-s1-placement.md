# 081 / 003 — S1: Collision-Free Placement and Following New Cards

## Context

New cards overlapped existing ones and appeared outside the viewport (see the
plan's Background). S1 fixes both without introducing layout modes.

## Change

- **`CanvasCardPlacement`** (`App/Sources/Features/Canvas/Models/CanvasCardPlacement.swift`)
  places new cards against the real frames of every stored card: right of the
  anchor, else below it, else the free slot (right of or below any card)
  nearest the anchor. Candidates keep `cardSpacing` from every card. Cards
  placed in one call chain off each other, so a batch gives the same result as
  one-at-a-time creation. `CanvasView.placeUnpositionedCards` uses it whenever
  some cards are already placed; a fresh canvas still gets the balanced grid.
  Stored layouts of cards that are not on the canvas right now (for example, a
  worktree whose terminal state is not loaded) are obstacles too, so they never
  come back underneath a new card.
- **Following new cards happens in the view, in the same pass as placement.**
  `CanvasView.followNewCard(among:states:)` focuses the last newly placed card
  that is the selected tab of its worktree and reveals it. Foreground creations
  select their tab (⌘T through Ghostty's `new_tab` or the New Terminal menu,
  the palette, the sidebar's new-tab action, `prowl create tab`); background
  creations do not, so they leave focus alone.
- **Reveal** (`CanvasViewportMath.reveal`) pans the least amount that shows the
  whole card. When the card does not fit at the current zoom, new cards zoom out
  just enough and center; spatial navigation keeps the user's zoom (its
  previous behavior, now through the same function).
- **The CLI stays in Canvas.** Foreground `prowl create tab` (shell or Profile)
  used to select the worktree, which left Canvas. In Canvas it now leaves the
  view alone and the new card follows the rule above
  (`ProwlApp.selectCLIWorktreeContextForNewTab`).
- The sidebar new-tab action in Canvas no longer needs the synchronous
  `TerminalClient.createTabInDirectory` endpoint (removed); it sends the regular
  `.createTabInDirectory` command. Undo-restored tabs still request focus through
  the reducer, now with `CanvasFocusRequest.Viewport.reveal`.
- A card renders once before it has a layout; it stays transparent for that
  frame instead of flashing at the canvas origin.

## Decision: why not drive this from the reducer

The first cut added the new tab ID to `TerminalClient.Event.tabCreated` and let
`AppFeature` issue a Canvas focus request for every focused creation. In the
Debug app, three fast ⌘T presses then placed the third card below the first:
the focus request for the second card had not reached the view yet, so the
anchor was stale and the result depended on typing speed again. Deciding focus
in the view, in the pass that places the card, removes that race.

## Verification

- `CanvasCardPlacementTests`: origin on an empty canvas; right of / below the
  anchor; no overlap and full spacing after a Tile layout for every anchor;
  batch equals sequential; reading-order fallback; determinism.
- `CanvasZoomMathTests`: reveal is a no-op when visible, pans to the far edge,
  zooms out to fit an oversized card, and keeps the zoom when not allowed.
- `RepositoriesFeatureTests`: the sidebar new-tab action stays in Canvas and
  sends one create command; undo restore requests a reveal.
- Prowl Debug (isolated data directory, in-process window capture): four tiled
  cards plus three ⌘T presses in quick succession — before: two new cards on the
  same slot and all three off-screen; after: three cards in a row to the right
  of the focused card, no overlap, the last one focused and in view.
  `prowl create tab` after Organize stays in Canvas and fills the next grid slot.
