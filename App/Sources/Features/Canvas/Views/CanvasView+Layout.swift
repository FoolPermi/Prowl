import SwiftUI

/// Card placement, automatic layouts, and the layout mode.
extension CanvasView {
  // MARK: - Cards

  /// Every card on the canvas, in canvas order: worktree order, then tab order.
  /// A tab is a card only once its surface exists.
  func canvasCards(in states: [WorktreeTerminalState]) -> [CanvasCardRef] {
    states.flatMap { state in
      state.tabManager.tabs.compactMap { tab in
        state.hasCanvasCard(tab.id) ? CanvasCardRef(worktreeID: state.worktreeID, tabID: tab.id) : nil
      }
    }
  }

  func currentCardKeys() -> [String] {
    canvasCards(in: terminalManager.activeWorktreeStates).map(\.key)
  }

  // MARK: - Layout Mode

  /// Lay out the cards the first time Canvas has both cards and a measured
  /// viewport: in the remembered automatic layout, or — on a fresh canvas — in
  /// the default layout from Settings. Freeform keeps the stored positions.
  func performEntryLayoutIfNeeded() {
    let keys = currentCardKeys()
    guard !hasPerformedInitialFit, hasMeasuredViewport, !keys.isEmpty else { return }
    hasPerformedInitialFit = true
    let defaultKind = settingsFile.global.canvasDefaultLayout.layoutKind
    if let kind = layoutStore.layoutForEntry(cardKeys: keys, defaultKind: defaultKind) {
      layoutCards(kind)
    }
    fitToView(canvasSize: viewportSize)
  }

  /// React to cards appearing or closing. In an automatic layout every card is
  /// laid out again and the viewport refits; in freeform new cards get free
  /// spots and nothing else moves. Either way a new foreground card takes focus.
  func handleCardSetChange(to cardKeys: [String]) {
    guard !cardKeys.isEmpty else { return }
    guard hasPerformedInitialFit else {
      // The first cards of an empty Canvas, or cards that arrived before the
      // viewport was measured.
      let placed = placeUnpositionedCards(cardKeys)
      performEntryLayoutIfNeeded()
      followNewCard(among: placed, states: terminalManager.activeWorktreeStates)
      return
    }

    let isExpandedCardShown = expandedTabID.map { cardKeys.contains($0.canvasCardKey) } ?? false
    let action =
      layoutStore.mode?.cardSetChangeAction(
        isCardExpanded: isExpandedCardShown,
        hasMeasuredViewport: hasMeasuredViewport
      ) ?? .placeNewCards
    switch action {
    case .relayout(let kind):
      let newKeys = cardKeys.filter { layoutStore.cardLayouts[$0] == nil }
      relayoutAutomatically(kind)
      followNewCard(among: newKeys, states: terminalManager.activeWorktreeStates)
    case .placeNewCards:
      followNewCard(among: placeUnpositionedCards(cardKeys), states: terminalManager.activeWorktreeStates)
    case .placeNewCardsAndRelayoutLater:
      followNewCard(among: placeUnpositionedCards(cardKeys), states: terminalManager.activeWorktreeStates)
      needsAutomaticRelayout = true
    }
  }

  /// Re-apply the automatic layout once a deferred change can run (the
  /// expanded card was restored).
  func relayoutIfDeferred() {
    guard needsAutomaticRelayout else { return }
    needsAutomaticRelayout = false
    guard let kind = layoutStore.mode?.automaticKind else { return }
    relayoutAutomatically(kind)
  }

  /// An automatic layout depends on the viewport, so a resized window lays the
  /// cards out again — once the size settles, to avoid reflowing every
  /// terminal on each frame of a live resize.
  func relayoutAfterViewportChange() async {
    guard hasPerformedInitialFit, hasMeasuredViewport,
      let kind = layoutStore.mode?.automaticKind,
      viewportSize != automaticLayoutViewportSize
    else { return }
    try? await Task.sleep(for: .milliseconds(300))
    guard !Task.isCancelled else { return }
    if expandedTabID != nil {
      needsAutomaticRelayout = true
    } else {
      relayoutAutomatically(kind)
    }
  }

  // MARK: - Automatic Layouts

  var hasMeasuredViewport: Bool {
    viewportSize.width > 0 && viewportSize.height > 0
  }

  func layoutShortcut(_ kind: CanvasLayoutKind) -> AppShortcut? {
    AppShortcuts.resolvedShortcut(for: kind.commandID, in: resolvedKeybindings)
  }

  /// Choose `kind` as the canvas's automatic layout and apply it. Shared by the
  /// toolbar buttons, the keyboard shortcuts, the command palette, and the CLI.
  func applyLayout(_ kind: CanvasLayoutKind) {
    layoutStore.mode = .automatic(kind)
    needsAutomaticRelayout = false
    withAnimation(expandAnimation) {
      cancelExpandForRelayout()
    }
    relayoutAutomatically(kind)
  }

  /// Lay out every card with `kind` and refit the viewport. Existing cards
  /// glide to their new frames; cards that had no frame yet appear directly at
  /// theirs instead of flying in from the canvas origin.
  func relayoutAutomatically(_ kind: CanvasLayoutKind) {
    guard let result = computeLayouts(kind) else { return }
    let newLayouts = result.layouts.filter { layoutStore.cardLayouts[$0.key] == nil }
    if !newLayouts.isEmpty {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        layoutStore.setCardLayouts(layoutStore.cardLayouts.merging(newLayouts) { _, new in new })
      }
    }
    withAnimation(expandAnimation) {
      layoutStore.applyLayouts(result.layouts, order: result.keys)
      fitToView(canvasSize: viewportSize)
    }
    automaticLayoutViewportSize = viewportSize
  }

  /// Lay out every card with `kind`, without animation or touching the
  /// viewport. A no-op when there are no cards, or when Arrange or Tile have
  /// no measured viewport yet.
  func layoutCards(_ kind: CanvasLayoutKind) {
    guard let result = computeLayouts(kind) else { return }
    layoutStore.applyLayouts(result.layouts, order: result.keys)
    automaticLayoutViewportSize = viewportSize
  }

  private func computeLayouts(_ kind: CanvasLayoutKind) -> (keys: [String], layouts: [String: CanvasCardLayout])? {
    let keys = currentCardKeys()
    let input = CanvasLayoutEngine.Input(
      keys: keys,
      cardSizes: layoutStore.cardLayouts.mapValues(\.size),
      viewport: viewportSize,
      defaultCardSize: adaptiveDefaultCardSize
    )
    let layouts = CanvasLayoutEngine.layouts(for: kind, input: input, metrics: layoutMetrics)
    return layouts.isEmpty ? nil : (keys, layouts)
  }

  /// A drag or resize by the user ends any automatic layout.
  func enterFreeformLayout() {
    layoutStore.mode = .freeform
    needsAutomaticRelayout = false
  }

  // MARK: - Placement

  /// Give every card that has no stored layout a position. On a fresh canvas
  /// the cards form a balanced grid; after that, each new card goes to a free
  /// spot next to the focused card without moving any other card.
  ///
  /// Returns the keys that were placed, in canvas order.
  @discardableResult
  func placeUnpositionedCards(_ cardKeys: [String]) -> [String] {
    let unpositioned = cardKeys.filter { layoutStore.cardLayouts[$0] == nil }
    guard !unpositioned.isEmpty else { return [] }
    let cardSize = adaptiveDefaultCardSize

    guard unpositioned.count < cardKeys.count else {
      let grid = CanvasGridLayout(spacing: layoutMetrics.cardSpacing, titleBarHeight: titleBarHeight)
      layoutStore.setCardLayouts(
        layoutStore.cardLayouts.merging(grid.layout(keys: unpositioned, cardSize: cardSize)) { _, new in new })
      return unpositioned
    }

    // Every stored card is an obstacle, including ones not on the canvas right
    // now: they come back where they were.
    let placement = CanvasCardPlacement(spacing: layoutMetrics.cardSpacing, titleBarHeight: titleBarHeight)
    let placed = placement.place(
      unpositioned.map { CanvasCardPlacement.NewCard(key: $0, size: cardSize) },
      existing: layoutStore.cardLayouts,
      anchorKey: selectionState.primaryTabID?.canvasCardKey
    )
    // Assign once to trigger a single save.
    layoutStore.setCardLayouts(layoutStore.cardLayouts.merging(placed) { _, new in new })
    return unpositioned
  }

  /// A tab created in the foreground — ⌘T, the palette, the sidebar, the CLI
  /// without `--background` — takes canvas focus as soon as its card is placed
  /// and is revealed, so the user always sees what they created. Focusing it in
  /// the same pass that placed it also makes it the anchor for the next new
  /// card, however quickly that one follows. Background creations leave focus
  /// and the view alone.
  func followNewCard(among placedKeys: [String], states: [WorktreeTerminalState]) {
    guard !placedKeys.isEmpty else { return }
    let newKeys = Set(placedKeys)
    let foregroundTabIDs = Set(states.compactMap(\.lastForegroundCreatedTabID))
    let card = CanvasNewCardFocus.cardToFollow(
      newKeys: newKeys,
      cards: canvasCards(in: states),
      foregroundTabIDs: foregroundTabIDs
    )
    // Claim the foreground marks of the cards placed now.
    for state in states {
      if let tabID = state.lastForegroundCreatedTabID, newKeys.contains(tabID.canvasCardKey) {
        state.lastForegroundCreatedTabID = nil
      }
    }
    guard let card else { return }
    // ⌘T inside an expanded card: show the new card instead of hiding it behind
    // the expansion.
    collapseExpand()
    focusSingleCard(card.tabID, states: states)
    revealCard(card.tabID, allowsZoomOut: true)
  }

  // MARK: - Viewport

  /// Adjust scale and offset so all cards fit within the viewport.
  func fitToView(canvasSize: CGSize) {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return }

    let bounds = currentCardKeys().reduce(CGRect.null) { bounds, key in
      guard let layout = layoutStore.cardLayouts[key] else { return bounds }
      return bounds.union(layout.frame(titleBarHeight: titleBarHeight))
    }

    guard
      let fit = CanvasViewportMath.fit(
        bounds: bounds,
        viewport: canvasSize,
        bottomReserve: bottomToolbarReserve,
        padding: viewportFitPadding
      )
    else {
      return
    }

    canvasOffset = fit.offset
    canvasScale = fit.scale
    lastCanvasScale = fit.scale
    lastCanvasOffset = canvasOffset
  }

  /// Animate the viewport to `target` with `viewportAnimator`, which drives
  /// the transform frame by frame (a SwiftUI animation would not reach the
  /// scroll container's bindings). A pan-only animation never writes the
  /// scale, so it cannot fight a zoom gesture that is in progress.
  func animateViewport(to target: CanvasViewportAnimator.Snapshot) {
    let start = CanvasViewportAnimator.Snapshot(offset: canvasOffset, scale: canvasScale)
    let animatesScale = start.scale != target.scale
    viewportAnimator.animate(from: start, to: target) { [self] snapshot in
      canvasOffset = snapshot.offset
      lastCanvasOffset = snapshot.offset
      if animatesScale {
        canvasScale = snapshot.scale
        lastCanvasScale = snapshot.scale
      }
    }
  }

  /// Remove stored layouts for tabs that no longer exist.
  func cleanStaleLayouts() {
    let visibleKeys = Set(currentCardKeys())
    guard !visibleKeys.isEmpty || hasSeenCanvasCards else { return }
    layoutStore.prune(to: visibleKeys)
  }
}

extension WorktreeTerminalState {
  /// A tab is a Canvas card once its surface exists.
  func hasCanvasCard(_ tabID: TerminalTabID) -> Bool {
    surfaceView(for: tabID) != nil
  }
}
