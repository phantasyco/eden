import SwiftUI

/// The right-hand panel: Changes, Files, Terminal, and Browser, plus a tab
/// for each subagent you've opened. It opens on a launcher; after that, icon
/// tabs switch between tools like the inspector tabs in Xcode. Each tool keeps
/// its own state (its shells, open file, page, scroll position) as you switch.
struct SidePanel: View {
    @Environment(AppModel.self) private var model
    /// Tools opened since the panel appeared. They stay alive, hidden, so
    /// switching back finds them as you left them.
    @State private var opened: Set<PanelTab> = []

    var body: some View {
        let current = model.visiblePanelTab
        VStack(spacing: 0) {
            // The launcher stands alone; the tools get their tab bar.
            if current != .home {
                PanelBar(current: current)
                Divider()
            }
            ZStack {
                if current == .home {
                    PanelLauncher()
                }
                ForEach(PanelTab.tools, id: \.self) { tool in
                    if opened.contains(tool) || tool == current {
                        content(tool)
                            .opacity(tool == current ? 1 : 0)
                            .allowsHitTesting(tool == current)
                            .accessibilityHidden(tool != current)
                    }
                }
                if case .subagent(let id) = current, let thread = model.selectedThread {
                    SubagentPanel(thread: thread, id: id)
                }
            }
        }
        .onChange(of: current, initial: true) { _, tab in
            if PanelTab.tools.contains(tab) { opened.insert(tab) }
        }
    }

    @ViewBuilder private func content(_ tool: PanelTab) -> some View {
        switch tool {
        case .changes:
            // A session's changes, or, with no session selected, the project's own.
            if let thread = model.selectedThread {
                DiffView(thread: thread)
                    .id(thread.id)
            } else if let repo = model.draftRepo {
                DiffView(thread: model.projectChanges(for: repo))
                    .id(repo.id)
            }
        case .files:
            if let folder = model.terminalFolder, let repo = model.selectedThread?.repo ?? model.draftRepo {
                FilesPanel(repo: repo, place: folder)
                    .id(folder)
            }
        case .terminal:
            if let folder = model.terminalFolder {
                TerminalPanel(folder: folder)
                    // One set of shells per folder: switching sessions shows
                    // that session's shells instead of carrying these along.
                    .id(folder)
            }
        case .browser:
            BrowserPanel(browser: model.browser)
        default:
            EmptyView()
        }
    }
}

/// The panel's top bar: an icon tab per tool, then subagent tabs. Expand
/// lives in the window's toolbar, beside the panel button.
private struct PanelBar: View {
    @Environment(AppModel.self) private var model
    let current: PanelTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.tools, id: \.self) { tool in
                Button { model.panelTab = tool } label: {
                    Label(tool.title, systemImage: tool.symbol)
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                        .background(Color.primary.opacity(tool == current ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tool == current ? .primary : .secondary)
                .disabled(!isAvailable(tool))
                .help("\(tool.title) (\(tool.shortcut))")
            }
            if let thread = model.selectedThread, !thread.openSubagents.isEmpty {
                Divider().frame(height: 16).padding(.horizontal, 6)
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(thread.openSubagents, id: \.self) { id in
                            PanelTabButton(title: thread.subagents[id]?.description ?? "Subagent", symbol: "person.2",
                                           isSelected: current == .subagent(id),
                                           select: { model.panelTab = .subagent(id) },
                                           close: { close(id, in: thread) })
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func isAvailable(_ tool: PanelTab) -> Bool {
        switch tool {
        case .changes, .files, .terminal: model.terminalFolder != nil
        default: true
        }
    }

    private func close(_ id: String, in thread: AgentThread) {
        thread.openSubagents.removeAll { $0 == id }
        if model.panelTab == .subagent(id) {
            model.panelTab = thread.openSubagents.last.map(PanelTab.subagent) ?? .changes
        }
    }
}

/// What the panel shows when it opens: a card per tool, with its shortcut.
private struct PanelLauncher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            ForEach(PanelTab.tools, id: \.self) { tool in
                LauncherCard(tool: tool, isAvailable: isAvailable(tool)) { model.panelTab = tool }
            }
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isAvailable(_ tool: PanelTab) -> Bool {
        switch tool {
        case .changes, .files, .terminal: model.terminalFolder != nil
        default: true
        }
    }
}

private struct LauncherCard: View {
    let tool: PanelTab
    let isAvailable: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                Text(tool.title)
                    .foregroundStyle(hovered ? .primary : .secondary)
                Spacer(minLength: 8)
                Text(tool.shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(hovered ? 0.06 : 0.02), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}
