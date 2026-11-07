import SwiftUI

/// Content of the menu bar popover. For now it only shows the app title.
public struct MenuBarPopover: View {
  /// Creates the popover content.
  public init() {}

  /// The popover's view hierarchy.
  public var body: some View {
    Text("popover.title", bundle: .main)
      .font(.headline)
      .padding()
      .frame(width: 320)
  }
}
