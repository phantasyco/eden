import AgentKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    @AppStorage(Preferences.sessionSort) private var sort = SessionSort.updated
    @AppStorage(Preferences.sessionPreviews) private var previews = true
    @State private var showArchived = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        // No list selection: rows draw their own (SidebarSelection), in the accent color.
        List {
            let composing = model.selection == .newChat
            // Icons in the theme's color, set on the image itself: the list's
            // own tint fell back to the system blue on the project folders.
            Label {
                Text("New Session")
            } icon: {
                Image(systemName: "square.and.pencil").foregroundStyle(composing ? .white : theme.color)
            }
            .sidebarSelection(composing) { model.newChat() }

            let pinned = model.pinnedThreads
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { row($0, showProject: true) }
                }
            }

            // A project is the folder the code lives in; its sessions sit under it.
            Section {
                ForEach(model.repos) { repo in
                    DisclosureGroup(isExpanded: expanded(repo)) {
                        ForEach(model.threads(for: repo)) { row($0) }
                    } label: {
                        ProjectRow(repo: repo)
                    }
                }
                // Sessions that work in a folder of their own, not a project.
                let loose = model.scratchThreads
                if !loose.isEmpty {
                    DisclosureGroup(isExpanded: expanded(key: AppModel.scratchGroup)) {
                        ForEach(loose) { row($0) }
                    } label: {
                        NoProjectRow()
                    }
                }
                if showsEmptyState {
                    Text(model.search.isEmpty ? "No Sessions" : "No Results")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .selectionDisabled()
                }
            } header: {
                ProjectsHeader(sort: $sort, previews: $previews)
            }

            let archived = model.archivedThreads
            if !archived.isEmpty {
                Section("Archived", isExpanded: $showArchived) {
                    ForEach(archived) { row($0, showProject: true) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsFooter()
        }
        .alert("Rename Session", isPresented: renaming) {
            TextField("Title", text: $model.renameText)
            Button("Rename") { model.commitRename() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.renaming = nil }
        }
    }

    private func row(_ thread: AgentThread, showProject: Bool = false) -> some View {
        ThreadRow(thread: thread, showProject: showProject, previews: previews)
            .sidebarSelection(model.selection == .thread(thread.id)) { model.selection = .thread(thread.id) }
            .contextMenu { ThreadMenu(thread: thread) }
    }

    /// Nothing to list: no sessions yet (archived ones don't count), or none match the search.
    private var showsEmptyState: Bool {
        model.pinnedThreads.isEmpty && model.scratchThreads.isEmpty && model.repos.allSatisfy { model.threads(for: $0).isEmpty }
    }

    private var renaming: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }

    private func expanded(_ repo: Repo) -> Binding<Bool> {
        expanded(key: repo.id)
    }

    private func expanded(key: String) -> Binding<Bool> {
        Binding(
            get: { !model.collapsedRepos.contains(key) },
            set: { isExpanded in
                if isExpanded { model.collapsedRepos.remove(key) } else { model.collapsedRepos.insert(key) }
            }
        )
    }
}

/// "Projects", with view options and Add Project on the right.
private struct ProjectsHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var sort: SessionSort
    @Binding var previews: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Projects")
            Spacer()
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SessionSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Show Previews", isOn: $previews)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View Options")
            Menu {
                Button("Add Project…", systemImage: "folder.badge.plus") { model.pickRepo() }
                Button("Clone a Project…", systemImage: "arrow.down.circle") { model.showCloneSheet = true }
                Button("Start from Scratch…", systemImage: "sparkles") { model.createRepo() }
                Divider()
                Button("Add Project on Another Machine…", systemImage: "server.rack") { model.showRemoteProjectSheet = true }
            } label: {
                Label("Add Project", systemImage: "folder.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add, clone, or start a project")
        }
    }
}

/// A project's folder row. Hovering shows its actions and "+" for a new
/// session there; the tooltip is the folder's path.
private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    let repo: Repo
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                HStack(spacing: 4) {
                    Text(repo.name)
                    // A project on another machine says where, like Zeron's "comet @ personal-metal".
                    if !repo.machine.isLocal {
                        Text("@ \(repo.machine.name)")
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            } icon: {
                Image(systemName: repo.machine.isLocal ? "folder" : "server.rack")
                    .foregroundStyle(theme.color)
            }
            Spacer(minLength: 4)
            if hovered {
                Menu {
                    ProjectMenu(repo: repo)
                } label: {
                    Label("Project Actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // Neutral, like the + beside it.
                .tint(.primary)
                .help("Project Actions")
                // Opens the new-session screen for this project. The session
                // joins the sidebar when you send its first message.
                Button { model.newChat(in: repo) } label: {
                    Label("New Session", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New Session in \(repo.name)")
            } else if running > 0 {
                ProgressView().controlSize(.mini)
                    .help("\(running) working")
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(repo.machine.isLocal ? repo.url.path : "\(repo.machine.name):\(repo.url.path)")
        .contextMenu { ProjectMenu(repo: repo) }
    }

    private var running: Int {
        model.threads.filter { $0.repo == repo && $0.isRunning }.count
    }
}

/// The selected row filled with the accent color, like the list in Notes,
/// with its text in white. Eden draws it: the sidebar's own selection is a
/// gray pill that can't take the theme's color.
private struct SidebarSelection: ViewModifier {
    let isSelected: Bool
    let select: () -> Void
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            // Secondary text inside becomes a softer white.
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10)
                    // Quieter in a window that's in the background, as macOS does.
                    .fill(theme.color.opacity(appearsActive ? 1 : 0.55))
                    .padding(.horizontal, 10)
                    .opacity(isSelected ? 1 : 0)
            )
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    fileprivate func sidebarSelection(_ isSelected: Bool, select: @escaping () -> Void) -> some View {
        modifier(SidebarSelection(isSelected: isSelected, select: select))
    }
}

/// The group for sessions without a project, with New Session on hover.
private struct NoProjectRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text("No Project")
            } icon: {
                Image(systemName: "square.dashed").foregroundStyle(theme.color)
            }
            Spacer(minLength: 4)
            if hovered {
                Button { model.newChatWithoutProject() } label: {
                    Label("New Session", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New Session Without a Project")
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("Sessions that each work in an empty folder of their own")
    }
}

/// Settings at the foot of the sidebar. No name or avatar: people share
/// screenshots of Eden, and those shouldn't carry who's using it.
private struct SettingsFooter: View {
    var body: some View {
        SettingsLink {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .help("Settings (⌘,)")
    }
}

private struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let repo: Repo

    var body: some View {
        Button("New Session in \(repo.name)", systemImage: "square.and.pencil") { model.newChat(in: repo) }
        if repo.machine.isLocal {
            Button("Show in Finder", systemImage: "folder") { Shell.open(repo.url) }
        }
        Button("Copy Path", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(repo.machine.isLocal ? repo.url.path : "\(repo.machine.name):\(repo.url.path)", forType: .string)
        }
        Divider()
        // Removes it from Eden only; the folder stays where it is.
        Button("Remove Project", systemImage: "minus.circle", role: .destructive) { model.removeRepo(repo) }
    }
}

/// A session's menu, from its row's context menu and the toolbar's More menu.
struct ThreadMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let thread: AgentThread

    var body: some View {
        Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") { model.togglePin(thread) }
        Button(thread.unread ? "Mark as Read" : "Mark as Unread", systemImage: thread.unread ? "circle" : "circle.inset.filled") {
            thread.unread.toggle()
        }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(value: thread.id) }
        Button("Fork", systemImage: "arrow.triangle.branch") { model.fork(thread) }
            .disabled(!thread.canFork)
        Button("Rename…", systemImage: "pencil") { model.beginRename(thread) }
        Button(thread.archived ? "Unarchive" : "Archive", systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox") {
            model.toggleArchive(thread)
        }
        .disabled(thread.isRunning)
        Divider()
        if thread.isRunning {
            Button("Stop", systemImage: "stop.circle") { thread.stop() }
        }
        if let worktree = thread.worktree, thread.repo.machine.isLocal {
            Button("Show in Finder", systemImage: "folder") { Shell.open(worktree) }
        }
        if let branch = thread.branch {
            Button("Copy Branch Name", systemImage: "doc.on.doc") { copy(branch) }
        }
        if let session = thread.sessionID {
            Button("Copy Session ID", systemImage: "number") { copy(session) }
        }
        Divider()
        // Deletes the conversation from Eden. Its worktree, if any, stays on disk.
        Button("Delete Session", systemImage: "trash", role: .destructive) { model.removeThread(thread) }
            .disabled(thread.isRunning)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Two lines, like Messages: title and time, then a preview underneath (or
/// just the title when previews are off). Hovering swaps the time for Pin and
/// Archive.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: AgentThread
    /// Pinned and archived rows sit outside their project, so they name it.
    var showProject = false
    var previews = true
    @State private var hovered = false

    var body: some View {
        HStack(alignment: previews ? .top : .center, spacing: 8) {
            // The model's mark leads the row, like a sender's picture in Mail.
            BrandIconView(icon: thread.agent.modelIcon, size: 14)
                .frame(width: 16, height: 16)
                .padding(.top, previews ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(thread.title)
                        .fontWeight(thread.unread ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                        // A fixed height, so swapping the time for buttons on
                        // hover doesn't change the row's height.
                        .frame(height: 16)
                }
                if previews || showProject {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    /// Pin and Archive on hover; otherwise what the session is doing, or when it last did something.
    @ViewBuilder private var trailing: some View {
        if hovered {
            HStack(spacing: 2) {
                RowButton(title: thread.pinned ? "Unpin" : "Pin", symbol: thread.pinned ? "pin.fill" : "pin") {
                    model.togglePin(thread)
                }
                RowButton(title: thread.isRunning ? "Stop it to archive" : thread.archived ? "Unarchive" : "Archive",
                          symbol: thread.archived ? "tray.and.arrow.up" : "archivebox") {
                    model.toggleArchive(thread)
                }
                .disabled(thread.isRunning)
            }
        } else if thread.isRunning {
            ProgressView().controlSize(.mini)
        } else if thread.isWaitingForYou {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Waiting for you")
        } else if case .failed = thread.state {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            HStack(spacing: 5) {
                if thread.unread {
                    Circle().fill(.tint).frame(width: 7, height: 7)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(shortAge(thread.updatedAt, now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        guard showProject else { return preview }
        return previews ? "\(thread.repo.name) · \(preview)" : thread.repo.name
    }

    private var preview: String {
        if thread.isRunning { return "\(thread.modelName) is working…" }
        if case .failed(let message) = thread.state { return message }
        for item in thread.items.reversed() {
            if case .assistant(let text) = item.kind {
                return Self.plain(text)
            }
        }
        return [thread.modelName, thread.branch].compactMap { $0 }.joined(separator: " · ")
    }

    /// The reply as one line of plain text: no Markdown marks, code, or tables.
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || trimmed.hasPrefix("|") || trimmed.isEmpty { continue }
            lines.append(String(trimmed.drop { "#>-*+ ".contains($0) }))
        }
        return lines.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    private func shortAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// An icon button on a sidebar row: sized to the row's text, with a quiet
/// fill on hover so it reads as a button.
private struct RowButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(hovered && isEnabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
