import AppKit
import SwiftUI

/// What sessions and the panel sit on. With Settings > Appearance > Window >
/// Translucent background on, it's the window's color over a blur of the
/// desktop, the color fading as far as the slider asks. The slider draws the
/// same two layers at every value, 0% included, so it has no step at the
/// bottom. Off (or with Reduce Transparency), the window's own background shows.
struct WindowBackdrop: View {
    /// Paint the window's color even with translucency off, to cover
    /// something underneath (the browser's blank page).
    var covers = false
    @AppStorage(Preferences.windowTranslucent) private var translucent = false
    @AppStorage(Preferences.windowTranslucency) private var translucency = 0.3
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if translucent && !reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
                .opacity(1 - translucency)
                .background { BehindWindowBlur() }
        } else if covers {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}
