import AgentKit
import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    var repos: [Repo] = []
    var threads: [AgentThread] = []
    var selection: Selection? = .newChat {
        didSet {
            selectedThread?.unread = false
            if let thread = selectedThread { Notifier.shared.clear(thread) }
            // Every move is history, except moving through history itself.
            if !navigatingHistory, let oldValue, oldValue != selection {
                backHistory.append(oldValue)
                if backHistory.count > 100 { backHistory.removeFirst() }
                forwardHistory.removeAll()
            }
        }
    }
    /// What Back and Forward (⌘[ and ⌘]) move through, like Safari's history.
    private var backHistory: [Selection] = []
    private var forwardHistory: [Selection] = []
    @ObservationIgnored private var navigatingHistory = false
    var columnVisibility = NavigationSplitViewVisibility.all
    /// The right-hand panel and the tab it shows: Changes, Terminal, or a subagent.
    var showPanel = false {
        didSet { if !showPanel { panelExpanded = false } }
    }
    var panelTab = PanelTab.home
    /// Each Files tab's place, by folder: the open file, expanded folders, the search.
    var filesState: [String: FilesState] = [:]
    /// Projects' own changes, for the Changes tab when no session is selected.
    @ObservationIgnored private var projectChangeSources: [String: ProjectChanges] = [:]

    func projectChanges(for repo: Repo) -> ProjectChanges {
        if let existing = projectChangeSources[repo.id] { return existing }
        let changes = ProjectChanges(repo: repo)
        projectChangeSources[repo.id] = changes
        return changes
    }

    /// The Browser tab's page, kept while you switch tabs and sessions.
    @ObservationIgnored lazy var browser = BrowserState()
    /// The panel filling the detail column, over the session.
    var panelExpanded = false
    let terminals = TerminalStore()
    var showWelcome = !UserDefaults.standard.bool(forKey: Preferences.hasSeenWelcome)
    var search = ""
    var collapsedRepos: Set<String> = []
    var lastError: String?
    /// The repository whose run command is being edited, shown as a sheet.
    var showCloneSheet = false
    var showRemoteProjectSheet = false
    /// The host the remote-project sheet starts on, when a picker already chose one.
    var remoteProjectHost: String?
    /// The agent whose Add MCP Server sheet is showing.
    var mcpSheetAgent: AgentKind?
    /// Each agent's MCP servers, as its CLI lists them; nil until checked.
    var mcpServers: [AgentKind: [MCPServer]] = [:]

    // Requests the views act on (focus changes can't live in the model).
    var focusSearchRequest = 0
    /// The session being renamed, and the title being typed for it.
    var renaming: AgentThread?
    var renameText = ""
    var focusComposerRequest = 0

    // The new-chat composer.
    var draftText = ""
    var draftRepo: Repo? {
        didSet { loadDraftBranches() }
    }
    var draftBranches: [String] = []
    var draftBranch: String?
    /// The 1M context window for the next session; nil means the model's default.
    var draftLongContext: Bool?
    /// Other models to run the same prompt with, each in its own session, to compare.
    var draftExtraModels: [String] = []
    var draftCheckout = Checkout.local
    /// The model decides the CLI: Anthropic runs through Claude Code, OpenAI through Codex.
    var draftModel = ModelCatalog.all[0] {
        didSet {
            if draftModel != oldValue {
                draftEffort = draftModel.defaultEffort
                draftServiceTier = nil
                draftLongContext = nil
            }
        }
    }
    var draftEffort: String?
    var draftServiceTier: String?
    var draftAccess = AccessMode.acceptEdits
    /// Whether the new session's project is a git repository.
    var draftIsGit = true
    var draftAttachments: [URL] = []

    @ObservationIgnored let installed: [AgentKind: Bool] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, Shell.which($0.binary) != nil) }
    )

    /// Each agent's own commands and skills per repository, for the slash menu.
    private var agentCommandLists: [String: [AgentCommand]] = [:]
    @ObservationIgnored private var loadingAgentCommands: Set<String> = []

    @ObservationIgnored private let store = ThreadStore()
    @ObservationIgnored private var handledLaunchArguments = false

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Preferences.repos) ?? []
        // Folders on this Mac that are gone drop out; remote ones can't be checked
        // without a connection, so they stay.
        repos = stored.compactMap(Repo.init(stored:))
            .filter { !$0.machine.isLocal || FileManager.default.fileExists(atPath: $0.url.path) }
        resetDraftDefaults()
        draftRepo = repos.first

        threads = store.load(repos: repos)
        threads.forEach(adopt)

        AgentModels.shared.refresh(installed: installed)

        Notifier.shared.start()
        Notifier.shared.open = { [weak self] id in
            guard let self, self.threads.contains(where: { $0.id == id }) else { return }
            self.selection = .thread(id)
        }

        // An agent can't outlive Eden: after a relaunch nothing could show or
        // stop it, and it would keep editing its worktree unseen. Stop agents
        // and run commands, then save, so running threads come back stopped.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for thread in self.threads {
                    thread.stop()
                    thread.closeSession()
                }
                self.terminals.closeAll()
                self.store.saveNow(self.threads)
            }
        }
    }

    var selectedThread: AgentThread? {
        guard case .thread(let id) = selection else { return nil }
        return threads.first { $0.id == id }
    }

    /// Where the terminal's shells run: the selected session's worktree (its
    /// project until the first message), else the new session's project.
    var terminalFolder: URL? {
        if let thread = selectedThread { return thread.repo.place(thread.worktree ?? thread.repo.url) }
        return draftRepo.map { $0.place($0.url) }
    }

    /// The tab the panel really shows: Changes needs a session, and a
    /// subagent tab belongs to the session that opened it.
    var visiblePanelTab: PanelTab {
        switch panelTab {
        case .changes where terminalFolder == nil, .files where terminalFolder == nil, .terminal where terminalFolder == nil: .home
        case .subagent(let id) where selectedThread?.openSubagents.contains(id) != true: .home
        default: panelTab
        }
    }

    func isShowing(_ tab: PanelTab) -> Bool {
        showPanel && visiblePanelTab == tab
    }

    /// Shows the panel on a tab, or hides it if it's already showing that tab.
    func togglePanel(_ tab: PanelTab) {
        if isShowing(tab) {
            showPanel = false
        } else {
            openPanel(tab)
        }
    }

    func openPanel(_ tab: PanelTab) {
        panelTab = tab
        showPanel = true
    }

    /// New Terminal (⌘D): opens the terminal, or adds another shell to it.
    func splitTerminal() {
        guard let folder = terminalFolder else { return }
        if isShowing(.terminal) { terminals.addPane(in: folder) } else { openPanel(.terminal) }
    }

    var runningCount: Int { threads.filter(\.isRunning).count }

    // MARK: History

    /// Removed threads stay in the history; Back and Forward skip them.
    var canGoBack: Bool { backHistory.contains(where: isStillThere) }
    var canGoForward: Bool { forwardHistory.contains(where: isStillThere) }

    func goBack() { move(from: &backHistory, to: &forwardHistory) }
    func goForward() { move(from: &forwardHistory, to: &backHistory) }

    private func move(from source: inout [Selection], to destination: inout [Selection]) {
        while let target = source.popLast() {
            guard isStillThere(target) else { continue }
            if let selection { destination.append(selection) }
            navigatingHistory = true
            selection = target
            navigatingHistory = false
            return
        }
    }

    private func isStillThere(_ selection: Selection) -> Bool {
        guard case .thread(let id) = selection else { return true }
        return threads.contains { $0.id == id }
    }

    /// A project's sessions in the sidebar: not pinned (those sit above the
    /// projects) and not archived.
    func threads(for repo: Repo) -> [AgentThread] {
        sorted(threads.filter { $0.repo == repo && !$0.pinned && !$0.archived && matchesSearch($0) })
    }

    var pinnedThreads: [AgentThread] {
        sorted(threads.filter { $0.pinned && !$0.archived && matchesSearch($0) })
    }

    /// Sessions that don't work in a project, grouped as "No Project".
    var scratchThreads: [AgentThread] {
        sorted(threads.filter { $0.repo.isScratch && !$0.pinned && !$0.archived && matchesSearch($0) })
    }

    /// The sidebar's key for the "No Project" group when it's collapsed.
    static let scratchGroup = "no-project"

    var archivedThreads: [AgentThread] {
        sorted(threads.filter { $0.archived && matchesSearch($0) })
    }

    private func matchesSearch(_ thread: AgentThread) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || thread.title.localizedCaseInsensitiveContains(query)
            || thread.repo.name.localizedCaseInsensitiveContains(query)
    }

    private func sorted(_ list: [AgentThread]) -> [AgentThread] {
        switch SessionSort(rawValue: UserDefaults.standard.string(forKey: Preferences.sessionSort) ?? "") ?? .updated {
        case .updated: list.sorted { $0.updatedAt > $1.updatedAt }
        case .title: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    func beginRename(_ thread: AgentThread) {
        renameText = thread.title
        renaming = thread
    }

    func commitRename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let thread = renaming, !title.isEmpty { thread.title = title }
        renaming = nil
    }

    /// A new session that starts from this one's conversation, in the same
    /// folder. Claude Code copies the session on its first message, so the
    /// original stays as it was.
    func fork(_ source: AgentThread) {
        guard source.canFork else { return }
        let thread = AgentThread(agent: source.agent, repo: source.repo)
        thread.title = "\(source.title) (Fork)"
        thread.access = source.access
        thread.checkout = source.checkout
        thread.baseBranch = source.baseBranch
        thread.worktree = source.worktree
        thread.branch = source.branch
        thread.sessionID = source.sessionID
        thread.forkPending = true
        thread.model = source.model
        thread.modelOverride = source.modelOverride
        thread.effort = source.effort
        thread.serviceTier = source.serviceTier
        thread.longContext = source.longContext
        thread.contextUsed = source.contextUsed
        thread.contextWindow = source.contextWindow
        for item in source.items { thread.append(item.kind, attachments: item.attachments) }
        thread.append(.note("Forked from \(source.title). New messages go to this copy; the original stays as it was."))
        thread.state = .idle
        register(thread)
        selection = .thread(thread.id)
    }

    /// A new session with the conversation up to the end of the turn that
    /// `itemID` is in. Claude Code and Codex copy their own conversation up to
    /// that point; OpenCode can copy all of it, so from its latest turn; any
    /// other branch starts fresh with the conversation so far sent as context.
    func branch(_ source: AgentThread, after itemID: String) {
        guard let start = source.items.firstIndex(where: { $0.id == itemID }) else { return }
        var end = start
        while end + 1 < source.items.count, !source.items[end + 1].isUser { end += 1 }
        let kept = Array(source.items[...end])
        let isLatest = end == source.items.count - 1
        let anchor = kept.last { $0.anchor != nil }?.anchor

        let thread = AgentThread(agent: source.agent, repo: source.repo)
        thread.title = "\(source.title) (Branch)"
        thread.access = source.access
        thread.checkout = source.checkout
        thread.baseBranch = source.baseBranch
        thread.worktree = source.worktree
        thread.branch = source.branch
        thread.model = source.model
        thread.modelOverride = source.modelOverride
        thread.effort = source.effort
        thread.serviceTier = source.serviceTier
        thread.longContext = source.longContext
        for item in kept { thread.append(item.kind, attachments: item.attachments) }

        let exact = (source.agent == .claude || source.agent == .codex) && (isLatest || anchor != nil)
        if source.sessionID != nil, exact || (source.agent.canFork && isLatest) {
            thread.sessionID = source.sessionID
            thread.forkPending = true
            thread.forkAnchor = isLatest ? nil : anchor
            thread.contextUsed = isLatest ? source.contextUsed : nil
            thread.contextWindow = source.contextWindow
            thread.append(.note("Branched from \(source.title). New messages go here; the original stays as it was."))
        } else {
            thread.branchContext = AgentThread.context(of: kept)
            thread.append(.note("Branched from \(source.title). This starts a new conversation with the one so far as its context."))
        }
        thread.state = .idle
        register(thread)
        selection = .thread(thread.id)
    }

    func togglePin(_ thread: AgentThread) {
        thread.pinned.toggle()
        if thread.pinned { thread.archived = false }
    }

    /// Archiving keeps the session and its worktree; it only folds the row
    /// away. A running session can't be archived.
    func toggleArchive(_ thread: AgentThread) {
        guard !thread.isRunning else { return }
        thread.archived.toggle()
        if thread.archived {
            thread.pinned = false
            thread.closeSession()
        }
    }

    // MARK: Repositories

    /// Adds any folder as a project. In a git repository, sessions can also
    /// work in their own worktrees and show their changes.
    @discardableResult
    func addRepo(_ url: URL) -> Repo? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            lastError = "\(url.lastPathComponent) isn't a folder."
            return nil
        }
        let repo = Repo(url: url.standardizedFileURL.resolvingSymlinksInPath())
        if !repos.contains(repo) {
            repos.append(repo)
            saveRepos()
        }
        if draftRepo == nil { draftRepo = repo }
        return repo
    }

    /// Moves the new session to another machine: to your most recently used
    /// project there, or, with none yet, to adding one.
    func chooseMachine(_ machine: Machine) {
        guard machine != draftRepo?.machine else { return }
        func lastUsed(_ repo: Repo) -> Date {
            threads.filter { $0.repo == repo }.map(\.updatedAt).max() ?? .distantPast
        }
        if let repo = repos.filter({ $0.machine == machine }).max(by: { lastUsed($0) < lastUsed($1) }) {
            draftRepo = repo
        } else {
            addProject(on: machine)
        }
    }

    /// Add Project for a machine: a folder panel for this Mac, the SSH sheet for another.
    func addProject(on machine: Machine) {
        switch machine {
        case .local:
            // After the popover that asked has closed.
            DispatchQueue.main.async { self.pickRepo() }
        case .ssh(let host):
            remoteProjectHost = host
            showRemoteProjectSheet = true
        }
    }

    /// Adds a folder on another machine as a project. Checking that it's
    /// there, and where `~` points, is one SSH round trip.
    func addRemoteRepo(host: String, path: String) async throws -> Repo {
        let machine = Machine.ssh(host)
        let command = machine.command("pwd", ["-P"], in: path)
        let out = try await Task.detached { try Shell.run(command.executable, command.arguments, cwd: nil) }.value
        let resolved = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.status == 0, resolved.hasPrefix("/") else {
            let detail = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EdenError(message: detail.isEmpty ? "Couldn't find \(path) on \(host)." : detail)
        }
        let repo = Repo(url: URL(fileURLWithPath: resolved), machine: machine)
        _ = await Task.detached { Git.isRepository(repo.url, on: machine, refresh: true) }.value
        if !repos.contains(repo) {
            repos.append(repo)
            saveRepos()
        }
        draftRepo = repo
        return repo
    }

    func removeRepo(_ repo: Repo) {
        repos.removeAll { $0 == repo }
        for thread in threads where thread.repo == repo && !thread.isRunning {
            thread.closeSession()
            store.delete(thread.id)
        }
        threads.removeAll { $0.repo == repo && !$0.isRunning }
        if draftRepo == repo { draftRepo = repos.first }
        if selectedThread == nil { selection = .newChat }
        saveRepos()
    }

    /// Where new and cloned repositories go: next to the ones you have, else ~/Projects.
    var projectsFolder: URL {
        if let parent = (draftRepo ?? repos.first)?.url.deletingLastPathComponent() { return parent }
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        return FileManager.default.fileExists(atPath: projects.path) ? projects : FileManager.default.homeDirectoryForCurrentUser
    }

    /// Start from Scratch: a new folder with git set up and a first commit.
    func createRepo() {
        let panel = NSSavePanel()
        panel.title = "Start from Scratch"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "New Project"
        panel.directoryURL = projectsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Git.create(at: url)
            if let repo = addRepo(url) { draftRepo = repo }
        } catch {
            lastError = "Couldn't create \(url.lastPathComponent).\n\n\(error.localizedDescription)"
        }
    }

    /// Clones a repository next to your others and selects it.
    func cloneRepo(_ remote: String, into parent: URL) async throws {
        let destination = try await Task.detached { try Git.clone(remote, into: parent) }.value
        if let repo = addRepo(destination) { draftRepo = repo }
    }

    func pickRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // New Folder, for a project that doesn't exist yet.
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = projectsFolder
        panel.message = "Choose the folder your code lives in, or make a new one with New Folder."
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url, let repo = addRepo(url) {
            draftRepo = repo
        }
    }

    // MARK: MCP servers

    /// Checks an agent's MCP servers once per launch, or again after adding one.
    /// `claude mcp list` health-checks each server, so it takes a few seconds.
    func loadMCPServers(for agent: AgentKind, force: Bool = false) {
        guard installed[agent] == true, force || mcpServers[agent] == nil else { return }
        if force { mcpServers[agent] = nil }
        Task { mcpServers[agent] = await MCP.servers(for: agent) }
    }

    // MARK: Slash commands

    func agentCommands(for repo: Repo, agent: AgentKind) -> [AgentCommand] {
        agentCommandLists["\(agent.rawValue) \(repo.id)"] ?? []
    }

    /// Asks the agent which commands and skills it offers in a repository, once
    /// per launch. Project skills live in the repo, so each repo gets its own list.
    /// The request runs on its own task: the view that asked may go away first
    /// (the new-chat screen does as soon as a thread starts), and cancelling the
    /// read used to cache an empty list for the rest of the launch.
    func loadAgentCommands(for repo: Repo, agent: AgentKind) {
        let key = "\(agent.rawValue) \(repo.id)"
        // A remote project's commands live on that machine; the menu keeps Eden's own.
        guard agent == .claude, installed[agent] == true, repo.machine.isLocal,
              agentCommandLists[key] == nil, !loadingAgentCommands.contains(key)
        else { return }
        loadingAgentCommands.insert(key)
        Task {
            let commands = await ClaudeCommands.load(in: repo.url)
            // Claude Code always lists its built-ins, so an empty list means the
            // request failed. Leaving it unset lets the next composer try again.
            if !commands.isEmpty { agentCommandLists[key] = commands }
            loadingAgentCommands.remove(key)
        }
    }

    // MARK: Threads

    /// Shows the new-chat composer, optionally preset to a repo.
    func newChat(in repo: Repo? = nil) {
        if let repo { draftRepo = repo }
        selection = .newChat
        focusComposerRequest += 1
    }

    /// A new session that works in an empty folder of its own, not a project.
    func newChatWithoutProject() {
        draftRepo = nil
        selection = .newChat
        focusComposerRequest += 1
    }

    /// Turns the new-chat composer into a running thread.
    func startDraftThread() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // No project: each session gets an empty folder of its own.
        func folder() -> Repo? {
            if let draftRepo { return draftRepo }
            do {
                return Repo(url: try Storage.newScratchFolder())
            } catch {
                lastError = "Couldn't make a folder for the session.\n\n\(error.localizedDescription)"
                return nil
            }
        }
        guard let repo = folder() else { return }
        // The first session is when "Eden can tell you when it's done" makes sense.
        Notifier.shared.requestPermission()
        // One session per model when comparing. They can't share one checkout
        // safely, so each gets a worktree of its own.
        let extras = draftExtraModels.compactMap(ModelCatalog.model).filter { $0 != draftModel && installed[$0.agent] == true }
        let comparing = !extras.isEmpty && repo.machine.isLocal
        var first: AgentThread?
        for (index, choice) in ([draftModel] + (comparing ? extras : [])).enumerated() {
            guard let place = index == 0 ? repo : folder() else { break }
            let thread = AgentThread(agent: choice.agent, repo: place)
            thread.modelOverride = choice.id
            let isMain = choice == draftModel
            thread.effort = isMain ? draftEffort : choice.defaultEffort
            thread.serviceTier = isMain ? draftServiceTier : nil
            thread.longContext = isMain ? draftLongContext : nil
            thread.access = draftAccess
            thread.checkout = comparing ? .worktree : draftCheckout
            thread.baseBranch = draftBranch
            register(thread)
            thread.send(prompt, attachments: draftAttachments)
            if comparing { thread.title = "\(thread.title) (\(choice.name))" }
            first = first ?? thread
        }
        if let first { selection = .thread(first.id) }
        draftText = ""
        draftAttachments = []
        draftExtraModels = []
    }

    /// Threads in sidebar order, for ⌘1–9 and previous/next.
    var orderedThreads: [AgentThread] {
        pinnedThreads + repos.filter { !collapsedRepos.contains($0.id) }.flatMap { threads(for: $0) }
            + (collapsedRepos.contains(Self.scratchGroup) ? [] : scratchThreads)
    }

    func selectThread(at index: Int) {
        let ordered = orderedThreads
        guard ordered.indices.contains(index) else { return }
        selection = .thread(ordered[index].id)
    }

    func selectAdjacentThread(_ offset: Int) {
        let ordered = orderedThreads
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { selection == .thread($0.id) } ?? (offset > 0 ? -1 : ordered.count)
        selectThread(at: min(max(current + offset, 0), ordered.count - 1))
    }

    func removeThread(_ thread: AgentThread) {
        guard !thread.isRunning else { return }
        thread.closeSession()
        threads.removeAll { $0.id == thread.id }
        store.delete(thread.id)
        // Shells in the thread's own worktree go with it; the repository's stay.
        if let worktree = thread.worktree, worktree != thread.repo.url { terminals.closeAll(in: worktree) }
        if selection == .thread(thread.id) { selection = .newChat }
        // The folder was made for this session; it goes to the Trash with it, where you can still get it back.
        if thread.repo.isScratch, !threads.contains(where: { $0.repo == thread.repo }) {
            try? FileManager.default.trashItem(at: thread.repo.url, resultingItemURL: nil)
        }
    }

    func finishWelcome() {
        showWelcome = false
        UserDefaults.standard.set(true, forKey: Preferences.hasSeenWelcome)
    }

    func toggleSidebar() {
        withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
    }

    /// `Eden --repo <path> [--model <id or name>] [--prompt <text> | --idle-thread] [--changes]`
    /// opens a repo and, with a prompt, starts a thread right away.
    func handleLaunchArguments() {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        guard let path = value("--repo"), let repo = addRepo(URL(fileURLWithPath: path)) else { return }
        draftRepo = repo
        if let model = ModelCatalog.model(value("--model")) { draftModel = model }
        if args.contains("--changes") { openPanel(.changes) }
        if let prompt = value("--prompt") {
            draftText = prompt
            startDraftThread()
        } else if args.contains("--idle-thread") {
            // Development: open a thread without sending anything, for layout tests.
            let thread = AgentThread(agent: draftModel.agent, repo: repo)
            thread.modelOverride = draftModel.id
            register(thread)
            selection = .thread(thread.id)
        }
    }

    // MARK: Private

    private func register(_ thread: AgentThread) {
        adopt(thread)
        threads.insert(thread, at: 0)
    }

    /// Hooks a new or restored thread up to the Dock badge, unread state, and saving.
    private func adopt(_ thread: AgentThread) {
        thread.onStateChange = { [weak self, weak thread] from in
            guard let self, let thread else { return }
            self.updateDockBadge()
            if !thread.isRunning, self.selection != .thread(thread.id) { thread.unread = true }
            // A turn that ran and ended; stopping it yourself isn't news.
            guard from == .running else { return }
            let visible = self.selection == .thread(thread.id)
            switch thread.state {
            case .finished: Notifier.shared.post(.finished, for: thread, isVisible: visible)
            case .failed(let message): Notifier.shared.post(.failed(message), for: thread, isVisible: visible)
            default: break
            }
        }
        thread.onRequest = { [weak self, weak thread] request in
            guard let self, let thread else { return }
            let what: String
            switch request.kind {
            case .approval(let tool, let summary):
                what = "\(thread.modelName) wants to use \(tool)" + (summary.isEmpty ? "." : ": \(summary.prefix(120))")
            case .questions(let questions):
                what = questions.first.map { "\(thread.modelName) asks: \($0.question)" } ?? "\(thread.modelName) has a question."
            }
            Notifier.shared.post(.needsYou(what), for: thread, isVisible: self.selection == .thread(thread.id))
        }
        store.track(thread)
    }

    private func resetDraftDefaults() {
        let defaults = UserDefaults.standard
        draftModel = ModelCatalog.preferred(installed: installed)
        draftEffort = draftModel.defaultEffort
        draftAccess = defaults.string(forKey: Preferences.defaultAccess).flatMap(AccessMode.init(rawValue:)) ?? .acceptEdits
        draftCheckout = defaults.string(forKey: Preferences.defaultCheckout).flatMap(Checkout.init(rawValue:)) ?? .local
    }

    private func loadDraftBranches() {
        guard let repo = draftRepo else {
            draftBranches = []
            draftBranch = nil
            return
        }
        // New worktrees are this Mac's for now; a remote project works in its checkout.
        if !repo.machine.isLocal { draftCheckout = .local }
        guard repo.machine.isLocal else {
            draftIsGit = Git.knownRepository(repo.url, on: repo.machine) ?? true
            // Over SSH this is a network round trip, so it doesn't hold up the screen.
            draftBranches = []
            draftBranch = nil
            Task {
                let branch = await Task.detached { Git.currentBranch(of: repo.url, on: repo.machine) }.value
                if draftRepo == repo { draftBranch = branch }
            }
            return
        }
        draftIsGit = Git.isRepository(repo.url, refresh: true)
        // A folder without git has no worktrees or branches; sessions work right in it.
        guard draftIsGit else {
            draftCheckout = .local
            draftBranches = []
            draftBranch = nil
            return
        }
        draftBranches = Git.branches(of: repo.url)
        draftBranch = Git.currentBranch(of: repo.url) ?? draftBranches.first
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = runningCount > 0 ? "\(runningCount)" : nil
    }

    private func saveRepos() {
        UserDefaults.standard.set(repos.map(\.stored), forKey: Preferences.repos)
    }
}
