import SwiftUI

/// The Terminal tab of the right-hand panel: one shell at a time, with a
/// strip of shells above it to switch, add, or close one, like tabs in
/// Terminal. Closing the last shell closes the panel.
struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    @AppStorage(Preferences.terminalTranslucent) private var translucent = true
    @AppStorage(Preferences.terminalOpacity) private var storedOpacity = 0.8
    // Reduce Transparency in Accessibility settings makes the terminal solid again.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // The margins' color follows the appearance from here, not from the
    // terminal view: SwiftUI doesn't know when the view repaints itself.
    @Environment(\.colorScheme) private var colorScheme
    let folder: URL

    private var opacity: Double { translucent && !reduceTransparency ? storedOpacity : 1 }

    var body: some View {
        let panes = model.terminals.panes(in: folder)
        let focused = model.terminals.focusedPane(in: folder)
        VStack(spacing: 0) {
            ShellStrip(folder: folder, panes: panes, focused: focused)
            Divider()
            ZStack {
                // Every shell stays alive; only the chosen one shows.
                ForEach(panes) { pane in
                    TerminalPaneView(pane: pane, accent: theme.color, opacity: opacity)
                        // SwiftTerm draws edge to edge; inset the text like Terminal does.
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The inset margins match the terminal: its color at the
                        // same opacity, over the blur when it's translucent.
                        .background(Color(nsColor: EdenTerminalView.background(dark: colorScheme == .dark).withAlphaComponent(opacity)))
                        .background {
                            if opacity < 1 { BehindWindowBlur() }
                        }
                        .opacity(pane.id == focused?.id ? 1 : 0)
                        .allowsHitTesting(pane.id == focused?.id)
                }
            }
        }
        .task(id: folder.path) { model.terminals.ensurePane(in: folder) }
        // Opening the terminal puts you in the shell, the way ⌘J does in other editors.
        .onAppear { model.terminals.focusedPane(in: folder)?.focusSoon() }
        .onChange(of: panes.isEmpty) { _, empty in
            if empty, model.panelTab == .terminal { model.showPanel = false }
        }
    }
}

/// The shells in this folder, with New Terminal at the end.
private struct ShellStrip: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    let panes: [TerminalPane]
    let focused: TerminalPane?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(panes) { pane in
                        TerminalRow(pane: pane, isFocused: pane.id == focused?.id,
                                    select: {
                                        model.terminals.focus(pane, in: folder)
                                        pane.focusSoon()
                                    },
                                    close: { model.terminals.close(pane, in: folder) })
                    }
                }
            }
            .scrollIndicators(.never)
            Button { model.terminals.addPane(in: folder) } label: {
                Label("New Terminal", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Terminal (⌘D)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct TerminalRow: View {
    let pane: TerminalPane
    let isFocused: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: "apple.terminal")
                        .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(pane.name)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(.plain)
            .help(pane.title.isEmpty ? pane.name : "\(pane.name): \(pane.title)")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered || isFocused ? 1 : 0)
            .help("Close Terminal")
        }
        .font(.callout)
        .foregroundStyle(isFocused ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(isFocused ? 0.09 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}
