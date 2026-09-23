import SwiftUI

/// A neutral control on the composer's glass: no glass of its own and no
/// tint, just a quiet rounded-rectangle fill on hover and while open. On the
/// Mac, small controls are rounded rectangles, not capsules.
struct ChipButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isActive: isActive)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isActive: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.15), value: hovered)
        }

        private var fill: Color {
            if configuration.isPressed || isActive { return Color.primary.opacity(0.12) }
            return hovered ? Color.primary.opacity(0.07) : .clear
        }
    }
}

/// The composer's round buttons. Send is prominent: the one tinted control on
/// the glass. Stop and the others are a neutral fill. The diameter is set so
/// the circle is concentric with the card's corner (card radius = diameter / 2
/// + the card's padding).
struct CircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 28
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, diameter: diameter, prominent: prominent)
    }

    private struct CircleBody: View {
        let configuration: Configuration
        let diameter: CGFloat
        let prominent: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: diameter * 0.46, weight: .semibold))
                .foregroundStyle(prominent && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: diameter, height: diameter)
                .background(fill, in: Circle())
                .contentShape(Circle())
                .brightness(configuration.isPressed ? (prominent ? -0.08 : 0.04) : 0)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.15), value: hovered)
        }

        private var fill: AnyShapeStyle {
            if prominent, isEnabled { return AnyShapeStyle(.tint) }
            if prominent { return AnyShapeStyle(Color.primary.opacity(0.08)) }
            return AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.16 : hovered ? 0.12 : 0.08))
        }
    }
}

/// Lays children out left to right and wraps to a new line when they run out
/// of room, so rows of controls never force their container wider.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0, widestItem: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            widestItem = max(widestItem, size.width)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widestLine = max(widestLine, x - spacing)
        }
        return CGSize(width: max(widestItem, min(widestLine, maxWidth)), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
