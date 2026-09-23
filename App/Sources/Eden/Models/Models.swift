import AgentKit
import Foundation

enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude, codex, cursor, grok, opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .opencode: "OpenCode"
        }
    }

    var binary: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .grok: "grok"
        case .opencode: "opencode"
        }
    }

    /// Who the models come from, as the picker's tabs name them. Cursor and
    /// OpenCode serve many companies' models, so they're providers of their own.
    var provider: String {
        switch self {
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        case .cursor: "Cursor"
        case .grok: "xAI"
        case .opencode: "OpenCode"
        }
    }

    /// The access modes the agent can honor. Cursor runs headless, so it can't
    /// stop to ask; Grok and OpenCode have no reviewer of their own.
    var accessModes: [AccessMode] {
        switch self {
        case .claude, .codex: AccessMode.allCases
        case .cursor: [.acceptEdits, .auto, .full]
        case .grok, .opencode: [.supervised, .acceptEdits, .full]
        }
    }

    /// The mode a session runs in when you picked one this agent doesn't have.
    func access(_ mode: AccessMode) -> AccessMode {
        accessModes.contains(mode) ? mode : .acceptEdits
    }

    /// Whether the CLI can copy a conversation into a new one.
    var canFork: Bool { self == .claude || self == .codex || self == .opencode }

    /// Whether Eden lists and adds MCP servers through the CLI's own commands.
    var managesMCP: Bool { self == .claude || self == .codex }

    static func effortLabel(_ effort: String?) -> String {
        switch effort {
        case nil: "Default Effort"
        case "xhigh": "Extra High"
        case "max": "Max"
        case "ultra": "Ultra"
        case let effort?: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

enum AccessMode: String, CaseIterable, Identifiable, Codable {
    // Raw values stay stable so saved preferences keep working.
    case supervised, acceptEdits = "standard", auto, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .supervised: "Supervised"
        case .acceptEdits: "Auto-accept Edits"
        case .auto: "Auto"
        case .full: "Full Access"
        }
    }

    var detail: String {
        switch self {
        case .supervised: "Asks you before it edits a file or runs a command."
        case .acceptEdits: "Edits files in the workspace without asking. Asks before anything else."
        case .auto: "The agent's own reviewer approves routine actions and blocks risky ones."
        case .full: "Runs any command and edits any file without asking."
        }
    }

    /// The detail, where an agent does it its own way.
    func detail(for agent: AgentKind) -> String {
        switch (self, agent) {
        case (.acceptEdits, .cursor): "Edits files without asking. Runs only the commands your Cursor allowlist permits."
        case (.auto, .cursor): "Cursor's reviewer approves routine commands and blocks risky ones."
        case (.supervised, .grok), (.supervised, .opencode):
            "Asks you before it edits a file or runs a command, when \(agent.displayName)'s own settings ask."
        default: detail
        }
    }

    var symbol: String {
        switch self {
        case .supervised: "hand.raised"
        case .acceptEdits: "pencil"
        case .auto: "wand.and.stars"
        case .full: "lock.open"
        }
    }
}

/// Where a thread's agent works. Current Checkout comes first: it's the default.
enum Checkout: String, CaseIterable, Identifiable, Codable {
    case local, worktree

    var id: String { rawValue }
    var label: String { self == .worktree ? "New Worktree" : "Current Checkout" }
    // Not the branch icon: the branch picker sits right next to this one.
    var symbol: String { self == .worktree ? "plus.square.on.square" : "folder" }
    var detail: String {
        self == .worktree
            ? "A new branch in its own folder. Your checkout stays untouched."
            : "Works right in your folder, on the branch you have checked out."
    }
}

enum RunState: Equatable, Codable {
    case idle, running, finished, failed(String)
}

enum Selection: Hashable {
    case newChat
    case thread(UUID)
}

/// A project: the git folder the code lives in, on this Mac or another machine.
struct Repo: Identifiable, Hashable {
    /// The folder's path, on its machine.
    let url: URL
    var machine = Machine.local

    init(url: URL, machine: Machine = .local) {
        self.url = url
        self.machine = machine
    }

    /// A saved project: a path on this Mac, or `ssh://host/path`.
    init?(stored: String) {
        if stored.hasPrefix("ssh://") {
            let rest = stored.dropFirst("ssh://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            self.init(url: URL(fileURLWithPath: String(rest[slash...])), machine: .ssh(String(rest[..<slash])))
        } else {
            self.init(url: URL(fileURLWithPath: stored))
        }
    }

    var stored: String {
        switch machine {
        case .local: url.path
        case .ssh(let host): "ssh://\(host)\(url.path)"
        }
    }

    var id: String { stored }
    var name: String { isScratch ? "No Project" : url.lastPathComponent }
    /// A session with no project works in an empty folder of its own, made
    /// for it in Eden's storage (see Storage.scratch).
    var isScratch: Bool { machine.isLocal && url.path.hasPrefix(Storage.scratch.path + "/") }
    /// "eden" on this Mac, "eden @ build-box" elsewhere.
    var title: String { machine.isLocal ? name : "\(name) @ \(machine.name)" }
    /// Where the terminal's shells run for this project's folder `path`.
    func place(_ path: URL) -> URL {
        switch machine {
        case .local: path
        case .ssh(let host): URL(string: "ssh://\(host)" + path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
        }
    }
}

/// Something the agent is waiting on you for: permission to use a tool, or
/// answers to questions it asked. It lives only as long as the agent's process.
struct AgentRequest: Identifiable {
    enum Kind {
        /// `summary` is what the tool would touch: a command, a file, a URL.
        case approval(tool: String, summary: String)
        case questions([AgentQuestion])
    }

    /// Which CLI asked, and how the answer goes back: a Claude Code control
    /// response, or a reply to a Codex JSON-RPC request.
    enum Origin {
        case claude
        case codex(rpcID: Any, method: String)
        /// An ACP agent (Grok, OpenCode): the reply picks one of its options.
        case acp(rpcID: Any, options: [[String: Any]])
    }

    /// The agent's own id for the request; the answer goes back under it.
    let id: String
    let kind: Kind
    /// The tool input as the agent sent it. Approving sends it back
    /// unchanged; answers are added to it.
    let input: [String: Any]
    /// Permission rules the agent offers for "Always Allow", like switching
    /// the session to accept edits.
    let suggestions: [Any]
    var origin = Origin.claude

    /// Whether "Always Allow" means something for this request.
    var canAlwaysAllow: Bool {
        switch origin {
        case .claude: !suggestions.isEmpty
        case .codex: true
        case .acp(_, let options): options.contains { $0["kind"] as? String == "allow_always" }
        }
    }
}

/// One question from the agent's AskUserQuestion tool.
struct AgentQuestion: Identifiable {
    struct Option: Hashable {
        let label: String
        let detail: String
    }

    var id: String { key }
    /// What the answer is filed under: the question's text for Claude Code, its id for Codex.
    var key: String
    let question: String
    /// A short tag for the question, like "Color".
    let header: String
    let options: [Option]
    let multiSelect: Bool
}

/// A subagent the agent started with its Agent tool: what it was asked, how
/// it's going, and its own transcript, which opens in the side panel.
struct SubagentRun: Codable {
    var description: String
    var kind: String?
    var prompt: String
    var status = ToolCall.Status.running
    /// Its latest step, like "Running tests", while it works.
    var activity: String?
    /// What it reported back when it finished.
    var summary: String?
    var items: [TranscriptItem] = []

    mutating func upsert(_ id: String, _ kind: TranscriptItem.Kind) {
        if let position = items.firstIndex(where: { $0.id == id }) {
            items[position].kind = kind
        } else {
            items.append(TranscriptItem(id: id, kind: kind))
        }
    }

    func toolCall(_ id: String) -> ToolCall? {
        guard let item = items.first(where: { $0.id == id }), case .tool(let call) = item.kind else { return nil }
        return call
    }
}

/// What the right-hand panel shows: the session's changes, a terminal in its
/// folder, or one of its subagents.
enum PanelTab: Hashable {
    /// The launcher: a card for each tool, shown when the panel opens.
    case home
    case changes
    case files
    case terminal
    case browser
    case subagent(String)

    static let tools: [PanelTab] = [.changes, .files, .terminal, .browser]

    var title: String {
        switch self {
        case .home: "Panel"
        case .changes: "Changes"
        case .files: "Files"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .subagent: "Subagent"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .changes: "plus.forwardslash.minus"
        case .files: "doc"
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .subagent: "person.2"
        }
    }

    var shortcut: String {
        switch self {
        case .changes: "⌘E"
        case .files: "⌘P"
        case .terminal: "⌘J"
        case .browser: "⇧⌘B"
        default: ""
        }
    }
}

/// A follow-up typed while the agent is working, sent when the turn finishes.
struct QueuedMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var attachments: [URL] = []
}

struct ToolCall: Codable {
    enum Status: String, Codable { case running, done, failed }

    var name: String
    var detail: String
    var output = ""
    var status = Status.running
}

struct TranscriptItem: Identifiable, Codable {
    enum Kind: Codable {
        case user(String)
        case assistant(String)
        case tool(ToolCall)
        /// What the model thought on the way: Codex's reasoning summaries,
        /// Claude's thinking, the other agents' thought stream.
        case thought(String)
        case note(String)
        case error(String)
    }

    let id: String
    var kind: Kind
    var date = Date()
    /// File names attached to a message, shown under the bubble.
    var attachments: [String]?
    /// Where the agent can pick the conversation up from after this item,
    /// for branching: Claude Code's message id, or the Codex turn it ended.
    var anchor: String?

    var isUser: Bool {
        if case .user = kind { return true }
        return false
    }
}

/// A model the user can pick. The provider decides which CLI runs it
/// (Anthropic through Claude Code, OpenAI through Codex); the UI never says which.
struct AIModel: Hashable, Identifiable {
    struct ServiceTier: Hashable {
        let id: String
        let name: String
        let detail: String
    }

    let id: String
    var name: String
    var detail: String
    let agent: AgentKind
    var efforts: [String]
    var defaultEffort: String?
    var serviceTiers: [ServiceTier] = []
    var isLegacy = false
    /// Tokens the model holds in context by default, when known.
    var contextWindow: Int?
    /// Offers the 1M-token context window, and whether it's on unless you say otherwise.
    var longContext = false
    var longContextByDefault = false
    /// What the CLI calls the model, when that differs from Eden's id: Eden
    /// prefixes other agents' ids ("cursor:gpt-5.5") so the same model served
    /// by two agents stays two choices.
    var cliID: String?
    /// Cursor lists each reasoning level and speed as its own model; this maps
    /// "effort|fast" to that model's id.
    var variants: [String: String] = [:]

    var provider: String { agent.provider }

    /// The model id to hand the CLI for this reasoning level and speed.
    func cliModel(effort: String?, fast: Bool) -> String {
        guard !variants.isEmpty else { return cliID ?? id }
        let level = effort ?? defaultEffort ?? ""
        return variants["\(level)|\(fast)"] ?? variants["\(level)|false"]
            ?? variants["\(defaultEffort ?? "")|\(fast)"] ?? variants["\(defaultEffort ?? "")|false"]
            ?? variants.values.sorted().first ?? cliID ?? id
    }

    static let longContextWindow = 1_000_000

    /// "200K", "1M": context sizes as the picker shows them.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            // 1,048,576 reads "1M", not "1.0M"; 1,500,000 reads "1.5M".
            let tenths = (Double(count) / 100_000).rounded()
            return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))M" : String(format: "%.1fM", tenths / 10)
        }
        return "\(count / 1_000)K"
    }
}

extension AIModel.ServiceTier {
    /// Claude Code's fast mode, for the models that offer it.
    static let fast = AIModel.ServiceTier(id: "fast", name: "Fast", detail: "Faster output, at a higher price")
}

enum ModelCatalog {
    static let anthropic: [AIModel] = {
        let full = ["low", "medium", "high", "xhigh", "max"]
        func claude(_ id: String, _ name: String, _ detail: String, _ efforts: [String], _ effort: String?, legacy: Bool = false) -> AIModel {
            AIModel(id: id, name: name, detail: detail, agent: .claude, efforts: efforts, defaultEffort: effort, isLegacy: legacy,
                    contextWindow: 200_000)
        }
        var opus = claude("claude-opus-5-5", "Opus 5.5", "Newest Opus", full, "medium")
        opus.serviceTiers = [.fast]
        opus.longContext = true
        opus.longContextByDefault = true
        var fable = claude("claude-fable-5-1", "Fable 5.1", "Most capable, for the hardest work", full, "medium")
        fable.longContext = true
        fable.longContextByDefault = true
        let known = [
            opus,
            fable,
            claude("claude-opus-5", "Opus 5", "Deep reasoning for complex tasks", full, "high"),
            claude("claude-sonnet-5", "Sonnet 5", "Fast and capable", full, "high"),
            claude("claude-fable-5", "Fable 5", "Previous Fable", full, "medium", legacy: true),
            claude("claude-opus-4-8", "Opus 4.8", "Previous Opus", full, "high", legacy: true),
            claude("claude-opus-4-7", "Opus 4.7", "Previous Opus", full, "xhigh", legacy: true),
            claude("claude-sonnet-4-6", "Sonnet 4.6", "Previous Sonnet", ["low", "medium", "high", "max"], "high", legacy: true),
            claude("claude-haiku-4-5", "Haiku 4.5", "Fastest and lowest cost", [], nil, legacy: true),
        ]
        return merged(known, live: ClaudeModelCache.load())
    }()

    /// Eden's list, corrected by what Claude Code last reported about each
    /// model (reasoning levels, fast mode, the 1M window), plus any model
    /// newer than Eden's list. The report is saved each launch for the next.
    static func merged(_ known: [AIModel], live: [[String: Any]]) -> [AIModel] {
        var models = known
        func baseID(_ model: String) -> String {
            var id = model.replacingOccurrences(of: "[1m]", with: "")
            // Dated snapshots ("-20251001") belong to the same model.
            if let dash = id.lastIndex(of: "-"), id[id.index(after: dash)...].count == 8,
               id[id.index(after: dash)...].allSatisfy(\.isNumber) {
                id = String(id[..<dash])
            }
            return id
        }
        for entry in live {
            guard let resolved = entry["resolvedModel"] as? String else { continue }
            let id = baseID(resolved)
            guard id.hasPrefix("claude-") else { continue }
            let long = (entry["value"] as? String ?? "").contains("[1m]") || resolved.contains("[1m]")
            let efforts = entry["supportedEffortLevels"] as? [String] ?? []
            let fast = entry["supportsFastMode"] as? Bool == true
            if let index = models.firstIndex(where: { $0.id == id }) {
                if long {
                    models[index].longContext = true
                    models[index].longContextByDefault = true
                }
                if !efforts.isEmpty { models[index].efforts = efforts }
                if fast, !models[index].serviceTiers.contains(.fast) { models[index].serviceTiers.append(.fast) }
            } else {
                let parts = (entry["description"] as? String ?? "").components(separatedBy: " · ")
                var model = AIModel(
                    id: id,
                    name: parts.first?.replacingOccurrences(of: " with 1M context", with: "") ?? id,
                    detail: parts.dropFirst().joined(separator: " · "),
                    agent: .claude, efforts: efforts, defaultEffort: efforts.contains("medium") ? "medium" : efforts.first,
                    contextWindow: 200_000, longContext: long, longContextByDefault: long
                )
                if fast { model.serviceTiers = [.fast] }
                models.insert(model, at: 0)
            }
        }
        return models
    }

    /// Codex caches the models your account can use, with their reasoning
    /// levels and service tiers, in ~/.codex/models_cache.json. Reading it keeps
    /// the list current. Models from the newest GPT generation count as current.
    static let openAI: [AIModel] = {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["models"] as? [[String: Any]]
        else {
            return [AIModel(id: "gpt-6-astra", name: "GPT-6-Astra", detail: "", agent: .codex,
                            efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium")]
        }
        let listed = entries
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
        func generation(_ slug: String) -> Double {
            let digits = slug.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            return Double(digits) ?? 0
        }
        let newest = listed.compactMap { ($0["slug"] as? String).map(generation) }.map { $0.rounded(.down) }.max() ?? 0
        return listed.compactMap { entry in
            guard let slug = entry["slug"] as? String else { return nil }
            let levels = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            let tiers = (entry["service_tiers"] as? [[String: Any]] ?? []).compactMap { tier -> AIModel.ServiceTier? in
                guard let id = tier["id"] as? String, let name = tier["name"] as? String else { return nil }
                return AIModel.ServiceTier(id: id, name: name, detail: tier["description"] as? String ?? "")
            }
            return AIModel(
                id: slug,
                name: entry["display_name"] as? String ?? slug,
                // The UI names models, not CLIs, so drop Codex's own branding.
                detail: (entry["description"] as? String ?? "").replacingOccurrences(of: " Codex model", with: " model"),
                agent: .codex,
                efforts: levels,
                defaultEffort: entry["default_reasoning_level"] as? String,
                serviceTiers: tiers,
                isLegacy: generation(slug).rounded(.down) < newest,
                // Codex keeps a share of the window for itself; this is what the model can use.
                contextWindow: (entry["context_window"] as? Int).map { window in
                    window * (entry["effective_context_window_percent"] as? Int ?? 100) / 100
                }
            )
        }
    }()

    /// Every model, including the lists Cursor, Grok, and OpenCode report,
    /// which can change while Eden runs (see AgentModels).
    static var all: [AIModel] { AgentModels.shared.all }

    static func model(_ id: String?) -> AIModel? {
        guard let id else { return nil }
        let needle = id.lowercased()
        return all.first { $0.id == id }
            ?? all.first { $0.name.lowercased() == needle }
            ?? all.first { $0.id.contains(needle) }
    }

    /// The saved default if its CLI is installed, else the first usable model.
    static func preferred(installed: [AgentKind: Bool]) -> AIModel {
        if let saved = model(UserDefaults.standard.string(forKey: Preferences.defaultModel)), installed[saved.agent] == true {
            return saved
        }
        return all.first { !$0.isLegacy && installed[$0.agent] == true } ?? all[0]
    }
}

/// Claude Code's own model list, from its reply to `initialize`, saved so the
/// next launch starts with it.
enum ClaudeModelCache {
    private static let key = "claudeModels"

    static func save(_ models: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: models) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
}
