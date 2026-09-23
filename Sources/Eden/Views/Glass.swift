import AppKit
import SwiftUI

/// Eden's glass: the system's Liquid Glass, with as much solid backing
/// behind its content as Settings > Appearance > Glass asks for. At 0 it's
/// pure glass; toward 100% the composer and the other floating controls turn
/// solid, so text scrolling underneath stops showing through.
private struct EdenGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @AppStorage(Preferences.glassOpacity) private var opacity = 0.0

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor).opacity(opacity), in: shape)
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}

extension View {
    /// Glass for Eden's floating controls; use it instead of `glassEffect` so the Glass setting reaches it.
    func edenGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(EdenGlass(shape: shape, interactive: interactive))
    }
}
