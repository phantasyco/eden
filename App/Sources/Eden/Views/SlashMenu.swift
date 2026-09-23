import SwiftUI

/// Selection and dismissal for one composer's slash menu.
@Observable
final class SlashMenuState {
    var selection = 0
    /// Escape hides the menu until the text changes.
    var dismissed = false

    func isShowing(_ suggestions: SlashSuggestions) -> Bool {
        !suggestions.isEmpty && !dismissed
    }

    /// The selected row, if the menu is open and has one.
    func selectedItem(in suggestions: SlashSuggestions) -> SlashItem? {
        guard isShowing(suggestions), !suggestions.items.isEmpty else { return nil }
        return suggestions.items[min(selection, suggestions.items.count - 1)]
    }
}

extension View {
    /// Up and Down move through the slash menu, Tab fills in the selected
    /// command, and Escape closes the menu. Return goes through the field's
    /// submit action, which picks the selected row when the menu is open.
    ///
    /// `suggestions` is a closure that reads the composer's live text. Key
    /// handlers can outlive the render they were made in, and a menu captured
    /// at render time let Return pick from a list the user had already filtered.
    func slashMenuKeys(
        text: String,
        state: SlashMenuState,
        suggestions: @escaping () -> SlashSuggestions,
        accept: @escaping (SlashItem, _ complete: Bool) -> Void
    ) -> some View {
        onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: [.down, .repeat]) { press in
            let suggestions = suggestions()
            guard state.isShowing(suggestions) else { return .ignored }
            if press.key == .escape {
                state.dismissed = true
                return .handled
            }
            let items = suggestions.items
            guard !items.isEmpty else { return .ignored }
            let current = min(state.selection, items.count - 1)
            switch press.key {
            case .upArrow: state.selection = (current - 1 + items.count) % items.count
            case .downArrow: state.selection = (current + 1) % items.count
            default: accept(items[current], true)
            }
            return .handled
        }
        .onChange(of: text) {
            state.selection = 0
            state.dismissed = false
        }
    }

    /// Floats the slash menu off one edge of a composer. It's an overlay, so it
    /// never changes the composer's size (see AGENTS.md on split-view columns).
    func slashMenu(
        _ suggestions: SlashSuggestions,
        state: SlashMenuState,
        edge: VerticalEdge,
        maxHeight: CGFloat = 320,
        accept: @escaping (SlashItem, _ complete: Bool) -> Void
    ) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            if state.isShowing(suggestions) {
                // A zero-height anchor on the composer's edge, with the menu
                // hanging off it. A custom alignment guide on the menu itself was
                // ignored, which left the menu covering the composer.
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: edge == .top ? .bottom : .top) {
                        SlashMenu(suggestions: suggestions, state: state, maxHeight: maxHeight, accept: accept)
                            .padding(edge == .top ? .bottom : .top, 8)
                    }
            }
        }
    }
}

/// A Spotlight-style list of commands on glass. Rows are one line tall so the
/// menu's height is known up front and never depends on text wrapping.
private struct SlashMenu: View {
    let suggestions: SlashSuggestions
    let state: SlashMenuState
    let maxHeight: CGFloat
    let accept: (SlashItem, _ complete: Bool) -> Void

    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 26
    private static let padding: CGFloat = 6

    private var items: [SlashItem] { suggestions.items }
    private var selection: Int { min(state.selection, max(items.count - 1, 0)) }

    /// Section headers only help when there's more than one section.
    private var showsHeaders: Bool {
        Set(items.map(\.section)).count > 1
    }

    private func startsSection(_ index: Int) -> Bool {
        showsHeaders && (index == 0 || items[index - 1].section != items[index].section)
    }

    private var listHeight: CGFloat {
        let headers = items.indices.filter(startsSection).count
        let content = CGFloat(items.count) * Self.rowHeight + CGFloat(headers) * Self.headerHeight + Self.padding * 2
        return min(content, maxHeight)
    }

    var body: some View {
        Group {
            if let hint = suggestions.hint {
                SlashRow(item: hint, isSelected: false)
                    .padding(Self.padding)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if startsSection(index) {
                                    Text(item.section)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .frame(maxWidth: .infinity, minHeight: Self.headerHeight, maxHeight: Self.headerHeight, alignment: .bottomLeading)
                                }
                                // Hovering highlights a row without selecting it: the menu
                                // can open under a resting pointer, and Return must act on
                                // the row the keyboard chose.
                                Button { accept(item, false) } label: {
                                    SlashRow(item: item, isSelected: index == selection)
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .padding(Self.padding)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: listHeight)
                    .onChange(of: state.selection) {
                        if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Icon, "/name", argument hint, one line of description, and a checkmark for
/// the current value. The selected row is filled with the accent, like a menu.
private struct SlashRow: View {
    let item: SlashItem
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let brand = item.brand {
                    BrandIconView(icon: brand, size: 15)
                } else {
                    Image(systemName: item.symbol ?? "circle")
                        .opacity(item.symbol == nil ? 0 : 1)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 18)
            Text(item.title)
                .lineLimit(1)
                .layoutPriority(2)
            if !item.hint.isEmpty {
                Text(item.hint)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let badge = item.badge {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary), in: Capsule())
            }
            Text(item.detail)
                .font(.callout)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isCurrent {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(.tint)
            } else if hovered {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
            }
        }
        .onHover { hovered = $0 }
    }
}
