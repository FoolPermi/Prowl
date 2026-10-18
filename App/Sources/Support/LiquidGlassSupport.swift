import AppKit
import SwiftUI

/// macOS 26's Liquid Glass material and the toolbar APIs that come with it, with
/// fallbacks for the app's macOS 15 deployment target.
///
/// Every custom glass surface, fixed toolbar spacer, hidden toolbar background, and
/// title-removing toolbar goes through this file. Two gates are needed, and each one
/// has a different job:
///
/// - `#if compiler(>=6.2)`: an SDK older than the macOS 26 SDK does not declare
///   `glassEffect`, `ToolbarSpacer`, `sharedBackgroundVisibility`, or
///   `toolbar(removing:)` at all, so the symbols must not appear in the source that
///   such a toolchain compiles.
/// - `#available(macOS 26.0, *)`: a binary built against the macOS 26 SDK still runs
///   on macOS 15, where the system must not draw Liquid Glass.
enum LiquidGlass {
  /// `true` when the running system draws Liquid Glass.
  static var isAvailable: Bool {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) { return true }
    #endif
    return false
  }
}

extension View {
  /// Draws Liquid Glass on macOS 26 and a material of the same shape earlier.
  ///
  /// The caller keeps owning its content and its own fill; this only supplies the
  /// surface behind it, matching the way `glassEffect` layers over a fill.
  @ViewBuilder
  func prowlGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      if interactive {
        glassEffect(.regular.interactive(), in: shape)
      } else {
        glassEffect(.regular, in: shape)
      }
    } else {
      background(.regularMaterial, in: shape)
    }
    #else
    background(.regularMaterial, in: shape)
    #endif
  }
}

/// A fixed toolbar spacer, which only macOS 26 draws.
///
/// Earlier systems space individual toolbar items themselves, so the spacer is an
/// empty item there instead of a visible gap.
struct ToolbarGroupSpacer: ToolbarContent {
  var body: some ToolbarContent {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      ToolbarSpacer(.fixed)
    } else {
      ToolbarItem { EmptyView() }
    }
    #else
    ToolbarItem { EmptyView() }
    #endif
  }
}

extension ToolbarContent {
  /// Hides the shared toolbar glass behind this item on macOS 26.
  ///
  /// macOS 15 draws a background per item instead of one shared surface, so the
  /// modifier is a no-op there and needs no replacement.
  @ToolbarContentBuilder
  func prowlHidingSharedBackground() -> some ToolbarContent {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
    #else
    self
    #endif
  }
}

extension View {
  /// Removes the window title from the toolbar, which only macOS 26 can do in SwiftUI.
  ///
  /// Earlier systems hide the title through the window instead; see `ToolbarTitleHider`.
  @ViewBuilder
  func prowlRemovingToolbarTitle() -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      toolbar(removing: .title)
    } else {
      background(ToolbarTitleHider())
    }
    #else
    background(ToolbarTitleHider())
    #endif
  }
}

/// Hides the hosted window's title on systems without `toolbar(removing:)`.
private struct ToolbarTitleHider: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    TitleHidingView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? TitleHidingView)?.hideWindowTitle()
  }

  private final class TitleHidingView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      hideWindowTitle()
    }

    func hideWindowTitle() {
      guard let window, window.titleVisibility != .hidden else { return }
      window.titleVisibility = .hidden
    }
  }
}
