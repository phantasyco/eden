import AgentKit
import Foundation
import Observation

/// One conversation with one agent, running in its own git worktree.
@MainActor @Observable
final class AgentThread: Identifiable, ChangeSource {
    let id: UUID
    let agent: AgentKind
    let repo: Repo
    var access = AccessMode.acceptEdits
    var title = "New Session"
    var worktree: URL?
    var branch: String?
    var sessionID: String?
    var model: String?
    var modelOverride: String?
    var effort: String?
    var serviceTier: String?
    var checkout = Checkout.worktree
    var baseBranch: String?
    var updatedAt = Date()
    var unread = false
    /// Pinned sessions sit above the projects; archived ones fold away at the bottom.
    var pinned = false
    var archived = false
    /// A fork that hasn't sent its first message: that message copies the
    /// session it came from into a new one.
    var forkPending = false
    /// A branch from an earlier turn: where the copied conversation stops
    /// (see TranscriptItem.anchor). Nil forks all of it.
    var forkAnchor: String?
    /// A branch the agent can't make itself: the conversation so far, sent
    /// ahead of the first message of a new session.
    var branchContext: String?
    var turnStartedAt: Date?
    var lastTurnDuration: TimeInterval?
    var costUSD = 0.0
    var items: [TranscriptItem] = []
    /// Follow-ups typed while the agent works; each goes out when a turn finishes.
    var queue: [QueuedMessage] = []
    /// Approvals and questions the agent is waiting on, oldest first.
    var requests: [AgentRequest] = [] {
        didSet { if requests.count > oldValue.count, let request = requests.last { onRequest?(request) } }
    }
    /// Subagents, by the id of the Agent tool call that started each one.
    var subagents: [String: SubagentRun] = [:]
    /// Subagents open as tabs in the right-hand panel.
    var openSubagents: [String] = []
    /// Tokens in the agent's context after its latest reply, and the model's limit.
    var contextUsed: Int?
    var contextWindow: Int?
    /// The 1M-token context window, for models that offer it. Nil means the model's default.
    var longContext: Bool?
    var diff = ""
    /// The diff parsed once per refresh, off the main thread. The Changes
    /// panel and the end-of-turn card read these instead of re-parsing a
    /// diff that can run to megabytes on every redraw.
    var diffFiles: [DiffFile] = []
    var diffStats = DiffStats("")
    /// False when the session's folder isn't in a git repository.
    var tracksChanges = true
    var state = RunState.idle {
        didSet { if state != oldValue { onStateChange?(oldValue) } }
    }

    @ObservationIgnored var onStateChange: ((_ from: RunState) -> Void)?
    @ObservationIgnored var onRequest: ((AgentRequest) -> Void)?
    @ObservationIgnored var turn = 0
    @ObservationIgnored var turnError: String?
    /// Files attached to the message being sent; copied into the working folder when the turn starts.
    @ObservationIgnored private var pendingAttachments: [URL] = []
    @ObservationIgnored var stopRequested = false

    // Claude Code's long-lived process and what the engine tracks about it (see ClaudeEngine.swift).
    @ObservationIgnored var session: ClaudeSession?
    // Codex's app-server, the turn it's running, and its subagents' threads.
    @ObservationIgnored var codex: CodexSession?
    @ObservationIgnored var codexTurnID: String?
    @ObservationIgnored var codexChildThreads: [String: String] = [:]
    // An ACP agent's process (Grok, OpenCode) and what the engine tracks about it (see ACPEngine.swift).
    @ObservationIgnored var acp: ACPSession?
    /// The session's options as the agent last reported them: model, reasoning, mode.
    @ObservationIgnored var acpOptions: [[String: Any]] = []
    @ObservationIgnored var acpImages = false
    @ObservationIgnored var acpReplaying = false
    @ObservationIgnored var acpMessage: String?
    @ObservationIgnored var acpThought: String?
    /// The running cost the agent last reported; nil until a reopened session reports one.
    @ObservationIgnored var acpCost: Double?
    // Cursor's run for the current turn (see CursorEngine.swift).
    @ObservationIgnored var cursor: AgentProcess?
    @ObservationIgnored var cursorMessage: String?
    @ObservationIgnored var cursorThought: String?
    @ObservationIgnored var cursorResult: [String: Any]?
    /// The thread's cost when the process started: Claude Code reports a running total per process.
    @ObservationIgnored var sessionCostBase = 0.0
    /// Text blocks being streamed, by message id, oldest first.
    @ObservationIgnored var streamingBlocks: [String: [String]] = [:]
    @ObservationIgnored var streamingMessage: String?
    /// Streamed text not yet shown, by transcript item. Shown in batches so a
    /// fast reply doesn't re-render the transcript for every word.
    @ObservationIgnored var streamBuffer: [String: String] = [:]
    @ObservationIgnored var streamFlush: Task<Void, Never>?
    @ObservationIgnored var idleReaper: Task<Void, Never>?
    @ObservationIgnored var interruptFallback: Task<Void, Never>?
    /// Agent tool calls whose subagents still run in the background.
    @ObservationIgnored var backgroundAgents: Set<String> = []
    @ObservationIgnored private var refreshingDiff = false
    @ObservationIgnored private var diffRefreshPending = false
    @ObservationIgnored private var index: [String: Int] = [:]

    var isRunning: Bool { state == .running }
    var isWaitingForYou: Bool { !requests.isEmpty }
    /// Claude Code, Codex, and OpenCode can copy a conversation into a new one.
    var canFork: Bool { agent.canFork && sessionID != nil && !isRunning }

    /// The access the agent runs with: the one you picked, or the closest one it has.
    var effectiveAccess: AccessMode { agent.access(access) }

    /// What the UI calls this thread's agent: the model's name, never the CLI's.
    var modelName: String {
        ModelCatalog.model(modelOverride)?.name ?? model ?? "Agent"
    }

    var catalogModel: AIModel {
        ModelCatalog.model(modelOverride) ?? ModelCatalog.all.first { $0.agent == agent } ?? ModelCatalog.all[0]
    }

    init(agent: AgentKind, repo: Repo, id: UUID = UUID()) {
        self.id = id
        self.agent = agent
        self.repo = repo
    }

    // MARK: Saving

    /// The thread as Eden saves it. The thread store reads this inside
    /// observation tracking, so every property here triggers a save.
    var record: ThreadRecord {
        ThreadRecord(
            id: id, agent: agent, repo: repo.stored, title: title, access: access,
            checkout: checkout, baseBranch: baseBranch, worktree: worktree?.path, branch: branch,
            sessionID: sessionID, model: model, modelOverride: modelOverride, effort: effort,
            serviceTier: serviceTier, updatedAt: updatedAt, unread: unread,
            lastTurnDuration: lastTurnDuration, costUSD: costUSD, state: state, turn: turn, items: items,
            queue: queue.isEmpty ? nil : queue, subagents: subagents.isEmpty ? nil : subagents,
            contextUsed: contextUsed, contextWindow: contextWindow, longContext: longContext,
            pinned: pinned ? true : nil, archived: archived ? true : nil, forkPending: forkPending ? true : nil,
            forkAnchor: forkAnchor, branchContext: branchContext
        )
    }

    /// Rebuilds a saved thread. A turn that was running when Eden quit comes
    /// back stopped, and a worktree that's been deleted takes its session with
    /// it, since the agent's session belongs to that folder.
    convenience init(record: ThreadRecord, repo: Repo) {
        self.init(agent: record.agent, repo: repo, id: record.id)
        title = record.title
        access = record.access
        checkout = record.checkout
        baseBranch = record.baseBranch
        branch = record.branch
        sessionID = record.sessionID
        model = record.model
        modelOverride = record.modelOverride
        effort = record.effort
        serviceTier = record.serviceTier
        updatedAt = record.updatedAt
        unread = record.unread
        lastTurnDuration = record.lastTurnDuration
        costUSD = record.costUSD
        turn = record.turn
        items = record.items
        queue = record.queue ?? []
        subagents = record.subagents ?? [:]
        contextUsed = record.contextUsed
        contextWindow = record.contextWindow
        longContext = record.longContext
        pinned = record.pinned ?? false
        archived = record.archived ?? false
        forkPending = record.forkPending ?? false
        forkAnchor = record.forkAnchor
        branchContext = record.branchContext
        for (position, item) in items.enumerated() { index[item.id] = position }
        worktree = record.worktree.map { URL(fileURLWithPath: $0, isDirectory: true) }

        if let worktree, !FileManager.default.fileExists(atPath: worktree.path) {
            self.worktree = nil
            branch = nil
            sessionID = nil
            append(.note("This session's worktree is gone, so the next message starts a new session in a new worktree."))
        }
        if record.state == .running {
            for (id, run) in subagents where run.status == .running { subagents[id]?.status = .failed }
            settleRunningTools()
            state = .idle
            append(.note("Stopped when Eden quit. Send a message to pick up where \(modelName) left off."))
        } else {
            state = record.state
        }
    }

    // MARK: Transcript

    func append(_ kind: TranscriptItem.Kind, id: String = UUID().uuidString, attachments: [String]? = nil) {
        index[id] = items.count
        items.append(TranscriptItem(id: id, kind: kind, attachments: attachments))
    }

    func upsert(_ id: String, _ kind: TranscriptItem.Kind) {
        if let i = index[id] {
            items[i].kind = kind
        } else {
            append(kind, id: id)
        }
    }

    func toolCall(_ id: String) -> ToolCall? {
        guard let i = index[id], case .tool(let call) = items[i].kind else { return nil }
        return call
    }

    func item(_ id: String) -> TranscriptItem? {
        index[id].map { items[$0] }
    }

    /// Marks the newest agent item with where the conversation can be picked up after it.
    func stampAnchor(_ anchor: String) {
        guard let last = items.indices.last, !items[last].isUser else { return }
        items[last].anchor = anchor
    }

    /// The conversation so far as plain text, for a branch or an edit the
    /// agent can't make itself and has to start over with.
    static func context(of items: [TranscriptItem]) -> String {
        let turns = items.compactMap { item -> String? in
            switch item.kind {
            case .user(let text): "Me: \(text)"
            case .assistant(let text): "You: \(text)"
            default: nil
            }
        }
        return "We're continuing an earlier conversation. Here it is, for context:\n\n" + turns.joined(separator: "\n\n")
            + "\n\nMy next message:"
    }

    /// Whether your last message can be edited or its reply regenerated.
    var canRewriteLast: Bool { !isRunning && items.contains(where: \.isUser) }

    /// Your last message, changed (or the same, to regenerate): it and
    /// everything after it go, and the conversation picks up from the end of
    /// the turn before. Claude Code and Codex rewind their own conversation to
    /// there (into a copy, so nothing is lost); the other agents start a new
    /// one with the earlier messages as context. Files the agent changed in
    /// the replaced reply stay as they are.
    func rewriteLastMessage(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRewriteLast, !text.isEmpty, let position = items.lastIndex(where: \.isUser) else { return }
        let before = Array(items[..<position])
        let anchor = before.last { $0.anchor != nil }?.anchor
        let hadTurns = before.contains(where: \.isUser)

        closeSession()
        items = before
        index = [:]
        for (position, item) in items.enumerated() { index[item.id] = position }
        subagents = subagents.filter { key, _ in index[key] != nil }
        openSubagents = openSubagents.filter { index[$0] != nil }
        contextUsed = nil

        if !hadTurns {
            // It was the first message: the conversation starts over.
            sessionID = nil
            branchContext = nil
        } else if sessionID != nil, agent == .claude || agent == .codex, let anchor {
            forkPending = true
            forkAnchor = anchor
        } else {
            sessionID = nil
            branchContext = Self.context(of: before)
        }
        if diffStats.files > 0 {
            append(.note("Files the earlier reply changed stay as they are; the new reply starts from them."))
        }
        send(text)
    }

    func removeItem(_ id: String) {
        guard let position = index[id] else { return }
        items.remove(at: position)
        index = [:]
        for (position, item) in items.enumerated() { index[item.id] = position }
    }

    // MARK: Running

    func send(_ prompt: String, attachments: [URL] = []) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        if items.isEmpty { title = String(text.prefix(60)) }
        append(.user(text), attachments: attachments.isEmpty ? nil : attachments.map(\.lastPathComponent))
        pendingAttachments = attachments
        begin(text)
    }

    // MARK: Queue

    func enqueue(_ prompt: String, attachments: [URL] = []) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.append(QueuedMessage(text: text, attachments: attachments))
    }

    func removeQueued(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// Whether a message can go to the agent while it works. Claude Code reads
    /// it at its next step and Codex adds it to the running turn; the others
    /// take it after the turn, from the queue.
    var canSteer: Bool {
        guard isRunning else { return false }
        switch agent {
        case .claude: return session?.isAlive == true
        case .codex: return codex?.isAlive == true && codexTurnID != nil
        case .cursor, .grok, .opencode: return false
        }
    }

    /// Sends a message into the running turn.
    func steer(_ prompt: String, attachments: [URL] = []) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSteer else { return }
        var message = text
        if !attachments.isEmpty, let worktree, let staged = try? Git.stageAttachments(attachments, in: worktree) {
            message += "\n\nAttached files, in this folder:\n" + staged.map { "- \($0)" }.joined(separator: "\n")
        }
        let id = UUID().uuidString
        append(.user(text), id: id, attachments: attachments.isEmpty ? nil : attachments.map(\.lastPathComponent))
        switch agent {
        case .claude: session?.sendUser(message)
        case .codex: steerCodex(text, message: message, itemID: id)
        case .cursor, .grok, .opencode: break
        }
    }

    /// Sends a queued message right away. Only while the agent is idle; a
    /// running turn has to finish (or be stopped) first.
    func sendQueuedNow(_ id: UUID) {
        guard !isRunning, let message = queue.first(where: { $0.id == id }) else { return }
        removeQueued(id)
        send(message.text, attachments: message.attachments)
    }

    /// After a turn finishes cleanly, the next queued message goes out. A
    /// failed or stopped turn leaves the queue for you to decide.
    func sendNextQueued() {
        guard !isRunning, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        send(next.text, attachments: next.attachments)
    }

    /// The last message you sent, for Try Again.
    var lastPrompt: String? {
        for item in items.reversed() {
            if case .user(let text) = item.kind { return text }
        }
        return nil
    }

    var canRetry: Bool {
        guard !isRunning, case .failed = state else { return false }
        return lastPrompt != nil
    }

    /// Runs the last message again after a failed turn, without repeating it
    /// in the transcript.
    func retry() {
        guard canRetry, let prompt = lastPrompt else { return }
        begin(prompt)
    }

    private func begin(_ prompt: String) {
        turn += 1
        turnError = nil
        stopRequested = false
        updatedAt = Date()
        turnStartedAt = Date()
        state = .running
        Task { await run(prompt) }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        if let session, session.isAlive {
            interruptClaude(session)
        } else if let codex, codex.isAlive {
            interruptCodex(codex)
        } else if let acp, acp.isAlive {
            interruptACP(acp)
        } else if let cursor, cursor.isAlive {
            interruptCursor(cursor)
        }
        // Otherwise the turn is still setting up (a worktree, attachments);
        // it checks stopRequested before starting the agent.
    }

    private func run(_ prompt: String) async {
        do {
            if worktree == nil {
                let repoURL = repo.url
                let machine = repo.machine
                let place = machine.isLocal ? repo.name : repo.title
                let isGit = await Task.detached { Git.isRepository(repoURL, on: machine, refresh: true) }.value
                // Without git there's no worktree to make; the session works in the folder.
                if !isGit { checkout = .local }
                switch checkout {
                case .worktree:
                    guard machine.isLocal else {
                        throw EdenError(message: "New worktrees on other machines aren't supported yet. Start this session in the project's current checkout.")
                    }
                    let name = String(id.uuidString.prefix(8)).lowercased()
                    let base = baseBranch
                    let created = try await Task.detached { try Git.createWorktree(repo: repoURL, name: name, base: base) }.value
                    // A project inside a bigger repository works in the same folder of the worktree.
                    let prefix = await Task.detached { Git.prefix(of: repoURL) }.value
                    worktree = prefix.isEmpty ? created.path : created.path.appendingPathComponent(prefix, isDirectory: true)
                    branch = created.branch
                    append(.note("Working on \(created.branch) in its own worktree, branched from \(base ?? "HEAD")"))
                case .local where isGit:
                    worktree = repoURL
                    branch = await Task.detached { Git.currentBranch(of: repoURL, on: machine) }.value
                    append(.note("Working directly in \(place)" + (branch.map { " on \($0)" } ?? ", on a detached HEAD")))
                case .local where repo.isScratch:
                    worktree = repoURL
                    append(.note("No project, so this session works in an empty folder of its own."))
                case .local:
                    worktree = repoURL
                    append(.note("Working directly in \(place). It isn't a git repository, so Eden can't show this session's changes."))
                }
            }
            guard let worktree else { return }
            // Stop can arrive while the worktree is being made; don't start the agent then.
            if stopRequested { return finishStopped() }

            var prompt = prompt
            // A branch the agent couldn't make: the conversation goes first, once.
            if let context = branchContext, sessionID == nil {
                prompt = context + "\n\n" + prompt
                branchContext = nil
            }
            var images: [String] = []
            if !pendingAttachments.isEmpty, !repo.machine.isLocal {
                pendingAttachments = []
                append(.note("Attachments stay on this Mac for now, so they weren't sent to \(repo.machine.name)."))
            }
            if !pendingAttachments.isEmpty {
                let files = pendingAttachments
                pendingAttachments = []
                let staged = try await Task.detached { try Git.stageAttachments(files, in: worktree) }.value
                prompt += "\n\nAttached files, in this folder:\n" + staged.map { "- \($0)" }.joined(separator: "\n")
                images = staged.filter { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
            }

            if stopRequested { return finishStopped() }

            // The turn runs in the agent's long-lived process; its events finish it.
            switch agent {
            case .claude: try startClaudeTurn(prompt, in: worktree)
            case .codex: try await startCodexTurn(prompt, images: images, in: worktree)
            case .grok, .opencode: try await startACPTurn(prompt, images: images, in: worktree)
            case .cursor: try startCursorTurn(prompt, in: worktree)
            }
            return
        } catch {
            settleRunningTools()
            append(.error(error.localizedDescription))
            state = .failed(error.localizedDescription)
        }
        if case .finished = state { sendNextQueued() }
        await refreshDiff()
    }

    func finishStopped() {
        settleRunningTools()
        append(.note("Stopped"))
        state = .idle
    }

    /// Tool calls the agent never finished (it was stopped, failed, or Eden
    /// quit) would otherwise spin forever; mark them failed. Subagents still
    /// working in the background keep going.
    func settleRunningTools() {
        for position in items.indices where !backgroundAgents.contains(items[position].id) {
            if case .tool(var call) = items[position].kind, call.status == .running {
                call.status = .failed
                items[position].kind = .tool(call)
            }
        }
    }

    /// Claude Code and its arguments for this session's long-lived process.
    /// (Codex's app-server takes its settings with each turn instead.)
    func command() throws -> (String, [String]) {
        guard let executable = Shell.which(AgentKind.claude.binary) else {
            throw EdenError(message: "Couldn't find `claude` on your PATH. Install \(AgentKind.claude.displayName) first.")
        }
        return (executable, claudeArguments())
    }

    func claudeArguments() -> [String] {
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            // Text as it's written, subagents' own text, and permission
            // prompts and questions sent to Eden instead of refused.
            "--include-partial-messages", "--forward-subagent-text", "--permission-prompt-tool", "stdio",
        ]
        if let modelOverride {
            args += ["--model", usesLongContext ? modelOverride + "[1m]" : modelOverride]
        }
        // Only models with effort levels take --effort (Haiku has none).
        if let effort, catalogModel.efforts.contains(effort) { args += ["--effort", effort] }
        if serviceTier == "fast", catalogModel.serviceTiers.contains(where: { $0.id == "fast" }) {
            args += ["--settings", #"{"fastMode":true}"#]
        }
        switch access {
        case .supervised: args += ["--permission-mode", "default"]
        case .acceptEdits: args += ["--permission-mode", "acceptEdits"]
        case .auto: args += ["--permission-mode", "auto"]
        case .full: args += ["--dangerously-skip-permissions"]
        }
        if let sessionID { args += ["--resume", sessionID] }
        if forkPending, sessionID != nil {
            args += ["--fork-session"]
            // Branching from an earlier turn keeps the conversation up to it.
            if let forkAnchor { args += ["--resume-session-at", forkAnchor] }
        }
        return args
    }

    // MARK: Changes

    /// Coalesces refreshes: a request that arrives mid-refresh runs once more afterward.
    /// Where this session's changes are: its worktree, or, before the first
    /// message, the checkout it's going to work in.
    var changesFolder: URL? {
        worktree ?? (checkout == .local ? repo.url : nil)
    }

    func refreshDiff() async {
        guard let folder = changesFolder else { return }
        if refreshingDiff {
            diffRefreshPending = true
            return
        }
        refreshingDiff = true
        repeat {
            diffRefreshPending = false
            let loaded = await DiffLoader.load(folder, on: repo.machine)
            diff = loaded.text
            diffFiles = loaded.files
            diffStats = loaded.stats
            tracksChanges = loaded.isGit
        } while diffRefreshPending
        refreshingDiff = false
    }

    func commit(message: String) async throws -> String {
        guard let worktree = changesFolder else { throw EdenError(message: "This session has no worktree yet.") }
        let machine = repo.machine
        let summary = try await Task.detached { try Git.commitAll(worktree: worktree, message: message, on: machine) }.value
        await refreshDiff()
        return summary
    }
}
