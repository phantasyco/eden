import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelInset) private var panelInset
    @Bindable var thread: AgentThread
    @State private var draft = ""
    @State private var attachments: [URL] = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        TranscriptView(thread: thread)
            // The composer floats on glass; the transcript scrolls beneath it,
            // softened by the bar's scroll edge effect.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ThreadComposer(thread: thread, draft: $draft, attachments: $attachments, focus: $composerFocused, model: modelBinding,
                               send: send, queue: queue)
                    .frame(maxWidth: 800)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    // Centered in the part the panel leaves visible.
                    .padding(.trailing, panelInset)
            }
        // A fixed minimum, like the detail column around it (see DetailArea and
        // AGENTS.md). Everything inside wraps or truncates to fit.
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        // A short title that doesn't change while the thread runs. The thread's
        // own title, branch, and cost change mid-run, so they live in the
        // transcript header instead: in a split view the window title is
        // toolbar content, and changing it near the truncation point made the
        // column's size limits oscillate until AppKit aborted.
        .navigationTitle(thread.repo.title)
        .toolbar {
            // The same items at all times. Adding and removing items as a
            // session starts and stops resized the toolbar mid-layout and crashed.
            ToolbarItemGroup {
                OpenMenu(folder: thread.worktree ?? thread.repo.url)
                    // Apps on this Mac can't open a folder on another machine.
                    .disabled(!thread.repo.machine.isLocal)
                MoreMenu(thread: thread)
            }
        }
        .onAppear { composerFocused = true }
        // Restored threads don't save their diff; read it from the worktree.
        .task { await thread.refreshDiff() }
    }

    private var modelBinding: Binding<AIModel> {
        Binding(
            get: { thread.catalogModel },
            set: { choice in
                thread.modelOverride = choice.id
                if let effort = thread.effort, !choice.efforts.contains(effort) { thread.effort = choice.defaultEffort }
                if !choice.serviceTiers.contains(where: { $0.id == thread.serviceTier }) { thread.serviceTier = nil }
                if !choice.longContext { thread.longContext = nil }
            }
        )
    }

    /// Sends. While the agent works the message goes into the running turn
    /// when the agent can take it (Claude reads it at its next step), and
    /// waits in the queue when it can't.
    private func send() {
        if thread.canSteer {
            thread.steer(draft, attachments: attachments)
        } else if thread.isRunning {
            thread.enqueue(draft, attachments: attachments)
        } else {
            thread.send(draft, attachments: attachments)
        }
        draft = ""
        attachments = []
    }

    /// Holds the message until the turn finishes, instead of sending it now.
    private func queue() {
        thread.enqueue(draft, attachments: attachments)
        draft = ""
        attachments = []
    }
}

/// The thread's composer: one glass card with queued follow-ups, the message
/// field, and the controls, with where the agent works in a quiet line
/// underneath. While the agent works, sending queues the message instead.
private struct ThreadComposer: View {
    @Environment(AppModel.self) private var app
    @Bindable var thread: AgentThread
    @Binding var draft: String
    @Binding var attachments: [URL]
    var focus: FocusState<Bool>.Binding
    let model: Binding<AIModel>
    let send: () -> Void
    let queue: () -> Void
    @State private var slash = SlashMenuState()
    @State private var dictation = Dictation()
    @AppStorage(Preferences.hiddenModels) private var hiddenModels = ""

    private static let button: CGFloat = 28
    private static let padding: CGFloat = 10

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A session can't change CLIs, so only same-provider models are offered.
    private var choices: [AIModel] {
        ModelVisibility.visible(ModelCatalog.all.filter { $0.agent == thread.agent }, hidden: hiddenModels, keeping: thread.catalogModel)
    }

    private var commands: SlashContext {
        SlashContext(
            app: app, repo: thread.repo, thread: thread, choices: choices,
            model: model, effort: $thread.effort, serviceTier: $thread.serviceTier, access: $thread.access
        )
    }

    var body: some View {
        let suggestions = commands.suggestions(for: draft)
        // One container for the card and the slash menu above it, so their
        // glass renders together instead of one sampling the other.
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 7) {
                card
                    .slashMenu(suggestions, state: slash, edge: .top, accept: accept)
                ComposerFooter(thread: thread)
                    .padding(.horizontal, 4)
            }
        }
        .task(id: thread.repo.id) { app.loadAgentCommands(for: thread.repo, agent: thread.agent) }
        // Typing, or sending, ends dictation without touching the message again.
        .onChange(of: draft) { if dictation.isActive, draft != dictation.written { dictation.abandon() } }
        .onDisappear { dictation.abandon() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Approvals and questions come first: the agent is stopped until you answer.
            if let request = thread.requests.first {
                RequestPanel(thread: thread, request: request)
                    .id(request.id)
                Divider()
            }
            if !thread.queue.isEmpty {
                QueuedMessages(thread: thread) { message in
                    // Editing takes it out of the queue and back into the field.
                    thread.removeQueued(message.id)
                    draft = message.text
                    attachments = message.attachments
                    focus.wrappedValue = true
                }
                Divider()
            }
            AttachmentChips(files: $attachments)
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused(focus)
                .onSubmit(submit)
                .slashMenuKeys(text: draft, state: slash, suggestions: { commands.suggestions(for: draft) }, accept: accept)
                .padding(.horizontal, 4)
                .padding(.top, 4)

            HStack(alignment: .center, spacing: 4) {
                if dictation.isActive {
                    DictationBar(dictation: dictation, diameter: Self.button)
                        .padding(.trailing, 4)
                } else {
                    ComposerAddMenu(agent: thread.agent, repo: thread.repo, attach: { attachments += $0 },
                                    insert: { draft = $0 + draft }, diameter: Self.button)
                        .padding(.trailing, 4)
                    FlowLayout(spacing: 2) {
                        ModelControls(
                            choices: choices,
                            model: model,
                            effort: $thread.effort,
                            serviceTier: $thread.serviceTier,
                            longContext: $thread.longContext,
                            access: $thread.access
                        )
                    }
                    .disabled(thread.isRunning)
                    Spacer(minLength: 0)
                    if thread.canSteer, hasText {
                        // Sending steers; this holds the message for after the turn instead.
                        Button("Queue", action: queue)
                            .buttonStyle(ChipButtonStyle())
                            .foregroundStyle(.secondary)
                            .keyboardShortcut(.return, modifiers: [.command, .shift])
                            .help("Send when \(thread.modelName) finishes (⇧⌘Return)")
                    }
                    DictationButton(dictation: dictation, text: $draft, diameter: Self.button)
                        .padding(.trailing, 4)
                    if thread.isRunning {
                        Button { thread.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(CircleButtonStyle(diameter: Self.button))
                        .help("Stop (⌘.)")
                    }
                }
                if !thread.isRunning || hasText {
                    Button(action: submit) {
                        Label(thread.isRunning && !thread.canSteer ? "Queue" : "Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(CircleButtonStyle(diameter: Self.button, prominent: true))
                    .disabled(!hasText)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(sendHelp)
                }
            }
        }
        .padding(Self.padding)
        // Concentric: the corner circles' radius plus the padding around them.
        .edenGlass(in: .rect(cornerRadius: Self.button / 2 + Self.padding))
        .acceptsAttachments($attachments)
    }

    private var placeholder: String {
        if thread.canSteer { return "Steer \(thread.modelName)" }
        if thread.isRunning { return "Queue a follow-up" }
        return "Message \(thread.modelName)"
    }

    private var sendHelp: String {
        if thread.canSteer { return "Send now (Return). \(thread.modelName) reads it at its next step." }
        if thread.isRunning { return "Queue (Return). It goes out when \(thread.modelName) finishes." }
        return "Send (Return). Option-Return adds a new line. Type / for commands."
    }

    /// Return picks the highlighted command while the menu is open, runs Eden's
    /// own commands, and sends everything else to the agent: into the running
    /// turn when it can take it, or the queue when it can't. Eden's commands work while the agent is busy, so
    /// /stop and /changes are always there.
    private func submit() {
        if let item = slash.selectedItem(in: commands.suggestions(for: draft)) {
            accept(item, complete: false)
            return
        }
        switch commands.run(draft) {
        case .done: draft = ""
        case .invalid: NSSound.beep()
        case .notCommand: if hasText { send() }
        }
    }

    private func accept(_ item: SlashItem, complete: Bool) {
        draft = commands.accept(item, complete: complete) { text in
            if thread.canSteer { thread.steer(text) } else if thread.isRunning { thread.enqueue(text) } else { thread.send(text) }
        }
    }
}

/// Follow-ups waiting for the current turn, oldest first. Each can go back
/// into the field for editing, or be removed; when the agent is idle (after a
/// failed or stopped turn) each can also be sent right away.
private struct QueuedMessages: View {
    @Bindable var thread: AgentThread
    let edit: (QueuedMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(thread.isRunning ? "Queued" : "Queued, Waiting for You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            ForEach(thread.queue) { message in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                    Text(message.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !message.attachments.isEmpty {
                        Label("\(message.attachments.count)", systemImage: "paperclip")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !thread.isRunning {
                        iconButton("Send Now", symbol: "arrow.up") { thread.sendQueuedNow(message.id) }
                    }
                    iconButton("Edit", symbol: "pencil") { edit(message) }
                    iconButton("Remove", symbol: "xmark") { thread.removeQueued(message.id) }
                }
                .font(.callout)
                .padding(.leading, 4)
            }
        }
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(ChipButtonStyle())
        .help(title)
    }
}

/// Where the agent works, in a muted line under the card, like a document's
/// status bar: the checkout and the branch, and how full the agent's context is.
private struct ComposerFooter: View {
    let thread: AgentThread

    /// Each group on a small glass capsule, so the transcript scrolling
    /// underneath doesn't run through the text.
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 14) {
                if !thread.repo.machine.isLocal {
                    Label(thread.repo.machine.name, systemImage: thread.repo.machine.symbol)
                }
                if thread.tracksChanges {
                    Label(thread.checkout.label, systemImage: thread.checkout.symbol)
                } else {
                    Label("Current Folder", systemImage: "folder")
                }
                if let branch = thread.branch ?? thread.baseBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .truncationMode(.middle)
                }
            }
            .modifier(FooterCapsule())
            Spacer(minLength: 0)
            if let used = thread.contextUsed, let window = thread.contextWindow, window > 0 {
                ContextGauge(used: used, window: window)
                    .modifier(FooterCapsule())
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A capsule of glass behind a footer group; it shares the composer's glass container.
private struct FooterCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .edenGlass(in: .capsule)
    }
}

/// How much of the model's context window the conversation fills: a small
/// ring and a percentage, amber from 75% and red from 90%, when it's time to
/// start a fresh session or let the agent compact.
struct ContextGauge: View {
    let used: Int
    let window: Int

    private var fraction: Double { min(1, Double(used) / Double(window)) }

    private var color: Color {
        switch fraction {
        case 0.9...: .red
        case 0.75...: .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text("\(Int((fraction * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(fraction >= 0.75 ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
        }
        .help("\(used.formatted()) of \(window.formatted()) tokens in context")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}

/// "Open in" for the thread's folder, listing only the apps that are installed.
private struct OpenMenu: View {
    let folder: URL

    private static let apps: [(name: String, bundleID: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"),
        ("Terminal", "com.apple.Terminal"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Zed", "dev.zed.Zed"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
    ]

    var body: some View {
        Menu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } label: {
                Label { Text("Finder") } icon: { AppIcon(bundleID: "com.apple.finder") }
            }
            Divider()
            ForEach(Self.apps, id: \.bundleID) { app in
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                    Button {
                        NSWorkspace.shared.open([folder], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
                    } label: {
                        Label { Text(app.name) } icon: { AppIcon(bundleID: app.bundleID) }
                    }
                }
            }
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        .help("Open the working folder in another app")
    }
}

/// An app's own icon at menu size, like the Open With menu in Finder.
private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            Image(nsImage: {
                icon.size = NSSize(width: 16, height: 16)
                return icon
            }())
        }
    }
}

private struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    let thread: AgentThread

    var body: some View {
        Menu {
            Button("Review Changes", systemImage: "plus.forwardslash.minus") { model.openPanel(.changes) }
            Button("Open Terminal", systemImage: "apple.terminal") { model.openPanel(.terminal) }
            Divider()
            // The same actions as the session's row in the sidebar.
            ThreadMenu(thread: thread)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelInset) private var panelInset
    let thread: AgentThread
    /// Following the bottom as the agent writes. Scrolling up stops it;
    /// scrolling back down to the bottom picks it up again.
    @State private var following = true
    /// Scrolls to the true end: past the last line and clear of the composer
    /// floating over it. Scrolling to a marker at the end left the last lines
    /// under the composer.
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var userScrolling = false
    /// The agent wrote more while you were scrolled up.
    @State private var unseen = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ThreadHeader(thread: thread)
                if thread.items.isEmpty {
                    EmptyThreadHint(thread: thread)
                }
                let rows = TranscriptRow.rows(thread.items)
                let ends = TurnEnd.find(in: rows, running: thread.isRunning)
                let lastUser = thread.canRewriteLast ? thread.items.last(where: \.isUser)?.id : nil
                let lastEnd = rows.last { ends[$0.id] != nil }?.id
                ForEach(rows) { row in
                    switch row {
                    case .item(let item):
                        if case .user = item.kind {
                            // Centered timestamps between turns, like Messages.
                            Text(timestamp(item.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 10)
                        }
                        if case .tool(let call) = item.kind, ClaudeEvents.isAgentTool(call.name), thread.subagents[item.id] != nil {
                            SubagentCard(thread: thread, id: item.id)
                        } else {
                            ItemView(item: item, retry: item.id == thread.items.last?.id && thread.canRetry ? { thread.retry() } : nil,
                                     edit: item.id == lastUser ? { thread.rewriteLastMessage($0) } : nil)
                        }
                    case .steps(let id, let items):
                        StepGroupView(items: items, live: thread.isRunning && id == rows.last?.id)
                    }
                    // The agent's reply ends here: Copy, Branch, and when.
                    if let end = ends[row.id] {
                        TurnActions(end: end,
                                    regenerate: row.id == lastEnd && lastUser != nil ? { regenerate() } : nil) {
                            model.branch(thread, after: end.itemID)
                        }
                    }
                }
                TurnStatus(thread: thread)
                if !thread.isRunning, thread.diffStats.files > 0 {
                    ChangesCard(stats: thread.diffStats) { model.openPanel(.changes) }
                }
            }
            .padding(20)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Clear of the panel without changing the scroll view's size (see DetailArea).
        .contentMargins(.trailing, panelInset, for: .scrollContent)
        .scrollPosition($position)
        // A session opens on its latest messages, like Messages.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
        }
        // Scrolling up, by hand, stops following; scrolling down doesn't,
        // and neither does the bounce back after scrolling past the end.
        .onScrollGeometryChange(for: [CGFloat].self) { geometry in
            [geometry.contentOffset.y, Self.bottomOffset(geometry)]
        } action: { old, new in
            if userScrolling, new[0] < old[0] - 1, old[0] <= old[1] + 1 { following = false }
        }
        // At the bottom again, it follows again.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y >= Self.bottomOffset(geometry) - 24
        } action: { _, bottom in
            atBottom = bottom
            if bottom {
                following = true
                unseen = false
            }
        }
        // Text streaming into the last message grows the content without
        // adding an item; following keeps the newest line in view.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
            guard new > old else { return }
            // Only `following` decides: the scroll phase can stay "interacting"
            // after a swipe ends, which left a transcript you'd scrolled back
            // down to sitting still.
            guard following else {
                unseen = true
                return
            }
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: thread.items.count) {
            // Your own message always brings you to the bottom.
            if case .user = thread.items.last?.kind { following = true }
            guard following else { return }
            withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            if !following && !atBottom {
                // A pill, like Messages' jump to new messages.
                Button {
                    following = true
                    unseen = false
                    withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Label(unseen ? "New Messages" : "Scroll to Bottom", systemImage: "arrow.down")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Clear glass, not the accent: the tint is for Send.
                .edenGlass(in: .capsule, interactive: true)
                .padding(.bottom, 12)
                // Centered in the part the panel leaves visible.
                .padding(.trailing, panelInset)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: following || atBottom)
    }

    /// Runs your last message again, as it is.
    private func regenerate() {
        guard let message = thread.items.last(where: \.isUser), case .user(let text) = message.kind else { return }
        thread.rewriteLastMessage(text)
    }

    /// The offset that shows the end of the transcript. The container's size
    /// already leaves out the toolbar and composer, and the offset counts
    /// from above the top inset.
    private static func bottomOffset(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top
    }

    private func timestamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.wide).month().day()) + " at \(time)"
    }
}

/// Where one of the agent's turns ends, and what Copy copies: all its text.
struct TurnEnd {
    let itemID: String
    let text: String
    let date: Date

    /// Each finished turn's last row, by row id. The turn still running has none yet.
    static func find(in rows: [TranscriptRow], running: Bool) -> [String: TurnEnd] {
        var ends: [String: TurnEnd] = [:]
        var turn: [TranscriptRow] = []
        func close() {
            defer { turn = [] }
            guard let lastRow = turn.last else { return }
            let items = turn.flatMap { row -> [TranscriptItem] in
                switch row {
                case .item(let item): [item]
                case .steps(_, let items): items
                }
            }
            let texts = items.compactMap { item -> String? in
                if case .assistant(let text) = item.kind { return text }
                return nil
            }
            guard !texts.isEmpty, let last = items.last else { return }
            ends[lastRow.id] = TurnEnd(itemID: last.id, text: texts.joined(separator: "\n\n"), date: last.date)
        }
        for row in rows {
            if case .item(let item) = row, item.isUser {
                close()
            } else {
                turn.append(row)
            }
        }
        if !running { close() }
        return ends
    }
}

/// Under each of the agent's replies: Copy, Branch in New Session, and the
/// time; under the latest, Regenerate too.
private struct TurnActions: View {
    let end: TurnEnd
    var regenerate: (() -> Void)?
    let branch: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            CopyButton(text: end.text)
            if let regenerate {
                MessageActionButton(title: "Regenerate", symbol: "arrow.clockwise", action: regenerate)
            }
            MessageActionButton(title: "Branch in New Session", symbol: "arrow.branch", action: branch)
            Text(end.date.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
        }
        .padding(.leading, -5)
    }
}

/// Copy, with a checkmark for a moment after.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        MessageActionButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

/// A small icon button under a message, with a quiet hover fill.
private struct MessageActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(hovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The thread's title with model, branch, and cost underneath, at the top of
/// the transcript (not in the window title; see ThreadView).
private struct ThreadHeader: View {
    let thread: AgentThread

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(thread.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 5) {
                BrandIconView(icon: thread.agent.modelIcon, size: 13)
                Text(details)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private var details: String {
        let cost = thread.costUSD > 0 ? String(format: "$%.2f", thread.costUSD) : nil
        return [thread.modelName, thread.branch, cost].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What the agent is doing right now and for how long ("Running swift build
/// · 42s") while a turn runs, "Worked for 1m 3s" after.
private struct TurnStatus: View {
    let thread: AgentThread

    var body: some View {
        if thread.isRunning, let start = thread.turnStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(duration(context.date.timeIntervalSince(start)))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        } else if let last = thread.lastTurnDuration {
            Text("Worked for \(duration(last))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    /// From the newest unfinished tool call, else what the last item suggests.
    private var activity: String {
        for item in thread.items.reversed() {
            switch item.kind {
            case .tool(let call) where call.status == .running:
                return Self.describe(call)
            case .thought:
                return "Thinking"
            case .tool, .note:
                continue
            case .assistant:
                return "Writing"
            case .user, .error:
                return "Thinking"
            }
        }
        return "Thinking"
    }

    static func describe(_ call: ToolCall) -> String {
        let detail = call.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = (detail as NSString).lastPathComponent
        func with(_ verb: String, _ object: String) -> String { object.isEmpty ? verb : "\(verb) \(object)" }
        switch call.name {
        case "Read", "NotebookRead": return with("Reading", file)
        case "Write": return with("Writing", file)
        case "Edit", "MultiEdit", "NotebookEdit": return with("Editing", file)
        case "Bash", "Shell", "Run": return with("Running", String(detail.prefix(80)))
        case "Grep", "Glob": return "Searching the code"
        case "WebSearch", "Web search": return "Searching the web"
        case "WebFetch": return "Reading a web page"
        case "Task", "Agent": return "Working with a subagent"
        case "TodoWrite": return "Updating the plan"
        default:
            if Step.kind(of: call) == .mcp { return with("Calling", Step.detail(of: call)) }
            return with("Using", call.name)
        }
    }
}

/// End-of-turn summary of the thread's changes, with a way into the diff.
private struct ChangesCard: View {
    let stats: DiffStats
    let review: () -> Void
    @AppStorage(Preferences.diffColors) private var colors = DiffColors.redGreen

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("\(stats.files) changed \(stats.files == 1 ? "file" : "files")")
                .font(.headline)
                .lineLimit(1)
            ChangeCounts(added: stats.added, removed: stats.removed, colors: colors)
            Spacer()
            Button("Review", action: review)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ItemView: View {
    let item: TranscriptItem
    var retry: (() -> Void)?
    /// For your last message: sends it again, changed, in place of the old one.
    var edit: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserMessage(text: text, attachments: item.attachments, edit: edit)
        case .assistant(let text):
            MarkdownText(text)
        case .tool, .thought:
            StepRow(item: item)
        case .note(let text):
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .error(let text):
            ErrorCallout(text: text, retry: retry)
        }
    }
}

/// Your message as a bubble on the right, with Copy beside it on hover,
/// and Edit on the last one, which turns the bubble into a field.
private struct UserMessage: View {
    let text: String
    let attachments: [String]?
    var edit: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @State private var editing = false
    @State private var changed = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if editing, let edit {
            editor(edit)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack(alignment: .center, spacing: 2) {
            Spacer(minLength: 80)
            // Your own words can be copied and, the last of them, edited; branching is for the agent's replies.
            Group {
                if edit != nil {
                    MessageActionButton(title: "Edit", symbol: "pencil") {
                        changed = text
                        editing = true
                        fieldFocused = true
                    }
                }
                CopyButton(text: text)
            }
            .opacity(hovered ? 1 : 0)
            VStack(alignment: .trailing, spacing: 5) {
                // A quiet fill, not the accent: the tint is for Send, and
                // your own words don't need to shout over the agent's.
                Text(text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(fill, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.leading, 4)
                if let files = attachments, !files.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(files, id: \.self) { file in
                            Label(file, systemImage: "paperclip")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onHover { hovered = $0 }
    }

    /// The message in a field where the bubble was, with Cancel and Send.
    private func editor(_ edit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Message", text: $changed, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...14)
                .focused($fieldFocused)
                .onSubmit { send(edit) }
                .onExitCommand { editing = false }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(fill, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.tint.opacity(0.6), lineWidth: 1))
            HStack(spacing: 8) {
                Text("Replaces this message and the reply after it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel") { editing = false }
                Button("Send") { send(edit) }
                    .buttonStyle(.borderedProminent)
                    .disabled(changed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.leading, 80)
    }

    private func send(_ edit: (String) -> Void) {
        let message = changed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        editing = false
        edit(message)
    }

    private var fill: Color { Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055) }
}

/// A failed turn: what went wrong, Copy for pasting it into an issue, and
/// Try Again when it's the latest thing that happened.
private struct ErrorCallout: View {
    let text: String
    let retry: (() -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(ChipButtonStyle())
            .help("Copy the error")
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.22)))
    }
}

private struct EmptyThreadHint: View {
    let thread: AgentThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(thread.modelName)
            } icon: {
                BrandIconView(icon: thread.agent.modelIcon, size: 22)
            }
            .font(.title2.weight(.semibold))
            Text("Ask for a change, then review the diff with the Changes button.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}
