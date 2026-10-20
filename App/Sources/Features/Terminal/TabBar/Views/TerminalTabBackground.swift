import SwiftUI

struct TerminalTabBackground: View {
  var isActive: Bool
  var isPressing: Bool
  var isDragging: Bool
  var isHovering: Bool

  var body: some View {
    Group {
      if isActive {
        // Selected tab floats as a Liquid Glass surface tinted by the
        // brightness-ladder fill on macOS 26, and as the same tint over a
        // material on macOS 15.
        Capsule()
          .fill(TerminalTabBarColors.activeTabBackground)
          .prowlGlass(Capsule())
      } else if isHovering || isPressing || isDragging {
        Capsule().fill(TerminalTabBarColors.hoveredTabBackground)
      } else {
        Capsule().fill(TerminalTabBarColors.inactiveTabBackground)
      }
    }
    // 1pt inset so the capsule floats with a small gap instead of touching the
    // bar/neighbor edges. Capsule (not a rounded rect) matches the tab's outer
    // .clipShape(.capsule); a rounded rect's corners would poke past the
    // capsule clip and get shaved off.
    .padding(1)
  }
}
