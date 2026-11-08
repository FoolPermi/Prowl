import SwiftUI

struct TerminalTabsView: View {
  @Bindable var manager: TerminalTabManager
  let renameTab: (TerminalTabID) -> Void
  let changeIcon: (TerminalTabID) -> Void
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let hasNotification: (TerminalTabID) -> Bool

  @State private var draggingTabId: TerminalTabID?
  @State private var draggingStartLocation: CGFloat?
  @State private var openedTabs: [TerminalTabID] = []
  @State private var tabLocations: [TerminalTabID: CGRect] = [:]
  @State private var closeButtonGestureActive = false
  @State private var containerWidth: CGFloat = 0
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    GeometryReader { geometryProxy in
      TabStripScrollHost(
        manager: manager,
        openedTabs: $openedTabs,
        tabLocations: $tabLocations,
        draggingTabId: $draggingTabId,
        draggingStartLocation: $draggingStartLocation,
        closeButtonGestureActive: $closeButtonGestureActive,
        fixedTabWidth: effectiveTabWidth,
        hasNotification: hasNotification,
        renameTab: renameTab,
        changeIcon: changeIcon,
        closeTab: closeTab,
        closeOthers: closeOthers,
        closeToRight: closeToRight,
        closeAll: closeAll,
        commandKeyObserver: commandKeyObserver,
        ghosttyShortcuts: ghosttyShortcuts,
        resolvedKeybindings: resolvedKeybindings
      )
      .onAppear {
        containerWidth = geometryProxy.size.width
      }
      .onChange(of: geometryProxy.size.width) { _, newWidth in
        containerWidth = newWidth
      }
    }
  }

  private var effectiveTabWidth: CGFloat? {
    let count = manager.tabs.count
    guard containerWidth > 0, count > 0 else { return nil }
    // Tabs split the bar equally and fill it (no max cap). Once the equal share
    // would dip below the minimum (too many tabs), pin to the minimum so the
    // row overflows and scrolls instead. Account for the row's horizontal
    // padding, inter-tab spacing, and the always-present dividers so a filled
    // row fits exactly — otherwise the leftover overflow lets selection-driven
    // scrollTo(.center) nudge the whole row when picking a middle tab.
    let interTabCount = CGFloat(count - 1)
    let available =
      containerWidth
      - TerminalTabBarMetrics.barPadding * 2
      - TerminalTabBarMetrics.tabSpacing * interTabCount
      - TerminalTabBarMetrics.tabDividerWidth * interTabCount
    let perTab = available / CGFloat(count)
    return max(TerminalTabBarMetrics.tabMinWidth, perTab)
  }
}

/// Hosts the scrollable tab strip in its own `NSHostingView`.
///
/// On macOS 15 a horizontal `ScrollView` nested under the window's transparent
/// titlebar keeps its `NSClipView` full bleed while it pads the scroll content
/// down by the top safe-area inset, yet it still sizes the document view to the
/// content's own height. The tabs then render below the document view's
/// hit-testable bounds, so AppKit resolves every click on the bar to the clip
/// view: selecting, hovering, and middle-clicking a tab all do nothing. A
/// hosting view starts a fresh AppKit container with a zero safe area, which
/// lays the clip and document views out consistently again.
private struct TabStripScrollHost: NSViewRepresentable {
  let manager: TerminalTabManager
  @Binding var openedTabs: [TerminalTabID]
  @Binding var tabLocations: [TerminalTabID: CGRect]
  @Binding var draggingTabId: TerminalTabID?
  @Binding var draggingStartLocation: CGFloat?
  @Binding var closeButtonGestureActive: Bool
  let fixedTabWidth: CGFloat?
  let hasNotification: (TerminalTabID) -> Bool
  let renameTab: (TerminalTabID) -> Void
  let changeIcon: (TerminalTabID) -> Void
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let commandKeyObserver: CommandKeyObserver
  let ghosttyShortcuts: GhosttyShortcutManager
  let resolvedKeybindings: ResolvedKeybindingMap

  func makeNSView(context: Context) -> NSHostingView<TabStripScrollContent> {
    let hostingView = NSHostingView(rootView: content)
    // The bar owns the strip's height; don't let the hosted content publish an
    // intrinsic size back into the surrounding layout.
    hostingView.sizingOptions = []
    return hostingView
  }

  func updateNSView(_ nsView: NSHostingView<TabStripScrollContent>, context: Context) {
    nsView.rootView = content
  }

  private var content: TabStripScrollContent {
    TabStripScrollContent(
      manager: manager,
      openedTabs: $openedTabs,
      tabLocations: $tabLocations,
      draggingTabId: $draggingTabId,
      draggingStartLocation: $draggingStartLocation,
      closeButtonGestureActive: $closeButtonGestureActive,
      fixedTabWidth: fixedTabWidth,
      hasNotification: hasNotification,
      renameTab: renameTab,
      changeIcon: changeIcon,
      closeTab: closeTab,
      closeOthers: closeOthers,
      closeToRight: closeToRight,
      closeAll: closeAll,
      commandKeyObserver: commandKeyObserver,
      ghosttyShortcuts: ghosttyShortcuts,
      resolvedKeybindings: resolvedKeybindings
    )
  }
}

/// The scrollable tab row, hosted inside `TabStripScrollHost`.
private struct TabStripScrollContent: View {
  @Bindable var manager: TerminalTabManager
  @Binding var openedTabs: [TerminalTabID]
  @Binding var tabLocations: [TerminalTabID: CGRect]
  @Binding var draggingTabId: TerminalTabID?
  @Binding var draggingStartLocation: CGFloat?
  @Binding var closeButtonGestureActive: Bool
  let fixedTabWidth: CGFloat?
  let hasNotification: (TerminalTabID) -> Bool
  let renameTab: (TerminalTabID) -> Void
  let changeIcon: (TerminalTabID) -> Void
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let commandKeyObserver: CommandKeyObserver
  let ghosttyShortcuts: GhosttyShortcutManager
  let resolvedKeybindings: ResolvedKeybindingMap

  var body: some View {
    ScrollViewReader { scrollReader in
      ScrollView(.horizontal) {
        TerminalTabsRowView(
          manager: manager,
          openedTabs: $openedTabs,
          tabLocations: $tabLocations,
          draggingTabId: $draggingTabId,
          draggingStartLocation: $draggingStartLocation,
          closeButtonGestureActive: $closeButtonGestureActive,
          fixedTabWidth: fixedTabWidth,
          hasNotification: hasNotification,
          renameTab: renameTab,
          changeIcon: changeIcon,
          closeTab: closeTab,
          closeOthers: closeOthers,
          closeToRight: closeToRight,
          closeAll: closeAll,
          scrollReader: scrollReader
        )
        .padding(.horizontal, TerminalTabBarMetrics.barPadding)
      }
      .scrollIndicators(.never)
      .onAppear {
        if let selectedId = manager.selectedTabId {
          scrollReader.scrollTo(selectedId, anchor: .center)
        }
      }
      .onChange(of: manager.selectedTabId) { _, newTabId in
        if let tabId = newTabId {
          withAnimation(.easeInOut(duration: TerminalTabBarMetrics.selectionAnimationDuration)) {
            scrollReader.scrollTo(tabId, anchor: .center)
          }
        }
      }
    }
    // The hosting view does not inherit the surrounding SwiftUI environment,
    // so forward the values the tab views read.
    .environment(commandKeyObserver)
    .environment(ghosttyShortcuts)
    .environment(\.resolvedKeybindings, resolvedKeybindings)
  }
}
