import AgentKit
import Foundation
import SwiftUI

// MARK: Commands

/// Commands Eden runs itself. They take precedence over an agent command with
/// the same name, because Eden owns the model, effort, and session settings the
/// CLI would otherwise change behind its back.
enum EdenCommand: String, CaseIterable {
    case model, effort, fast, access, new, clear, changes, commit, rename, stop

    enum Argument { case none, choice, text }

    var argument: Argument {
        switch self {
        case .model, .effort, .access: .choice
        case .commit, .rename: .text
        default: .none
        }
    }

    var aliases: [String] {
        switch self {
        case .effort: ["reasoning"]
        case .access: ["permissions"]
        case .clear: ["reset"]
        case .changes: ["diff"]
        default: []
        }
    }

    var argumentHint: String {
        switch self {
        case .model: "<model>"
        case .effort: "<level>"
        case .access: "<mode>"
        case .commit: "<message>"
        case .rename: "<title>"
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .model: "cpu"
        case .effort: "bolt"
        case .fast: "hare"
        case .access: "hand.raised"
        case .new: "square.and.pencil"
        case .clear: "eraser"
        case .changes: "sidebar.trailing"
        case .commit: "checkmark.circle"
        case .rename: "pencil"
        case .stop: "stop.circle"
        }
    }

    static func named(_ name: String) -> EdenCommand? {
        let name = name.lowercased()
        return allCases.first { $0.rawValue == name || $0.aliases.contains(name) }
    }

    /// Every name Eden claims, so agent commands with these names stay hidden.
    static let reservedNames = Set(allCases.flatMap { [$0.rawValue] + $0.aliases })
}

/// A command or skill the agent's CLI offers. Eden sends it as typed.
struct AgentCommand: Hashable {
    let name: String
    let detail: String
    let argumentHint: String
    let aliases: [String]

    /// Claude Code writes required arguments as `<message>` and optional ones as
    /// `[name]` (or `<optional …>`). A command that needs one waits for it.
    var needsArgument: Bool {
        argumentHint.hasPrefix("<") && !argumentHint.localizedCaseInsensitiveContains("optional")
    }
}

/// The composer's text read as "/name" or "/name argument".
struct SlashQuery {
    let name: String
    /// Nil while the name is still being typed; set once a space follows it.
    let argument: String?

    init?(_ text: String) {
        guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return nil }
        let body = text.dropFirst()
        if let space = body.firstIndex(where: \.isWhitespace) {
            name = String(body[..<space])
            argument = body[space...].trimmingCharacters(in: .whitespaces)
        } else {
            name = String(body)
            argument = nil
        }
    }
}

// MARK: Menu content

/// One row in the slash menu.
struct SlashItem: Identifiable {
    enum Action {
        case command(EdenCommand)
        case value(EdenCommand, String)
        case agent(AgentCommand)
    }

    let id: String
    let section: String
    var symbol: String?
    /// Drawn instead of the symbol: models and the agent's own commands.
    var brand: BrandIcon?
    let title: String
    var hint = ""
    var detail = ""
    var badge: String?
    var isCurrent = false
    let action: Action
}

/// What the menu shows for the composer's text: rows to pick from, or one
/// hint row describing the command whose argument is being typed.
struct SlashSuggestions {
    var items: [SlashItem] = []
    var hint: SlashItem?

    var isEmpty: Bool { items.isEmpty && hint == nil }
}

// MARK: Context

/// Everything one composer's slash commands can act on. The thread composer
/// passes its thread; the new-chat composer passes nil and acts on the draft.
@MainActor
struct SlashContext {
    enum Outcome { case notCommand, done, invalid }

    let app: AppModel
    let repo: Repo?
    let thread: AgentThread?
    let choices: [AIModel]
    @Binding var model: AIModel
    @Binding var effort: String?
    @Binding var serviceTier: String?
    @Binding var access: AccessMode

    private var isRunning: Bool { thread?.isRunning ?? false }

    private var fastTier: AIModel.ServiceTier? {
        model.serviceTiers.first { $0.name.caseInsensitiveCompare("Fast") == .orderedSame }
    }

    private var installedChoices: [AIModel] {
        choices.filter { app.installed[$0.agent] == true }
    }

    /// The agent's own commands, hidden while it works (they'd have to wait for the turn anyway).
    private var agentCommands: [AgentCommand] {
        guard let repo, !isRunning else { return [] }
        return app.agentCommands(for: repo, agent: model.agent)
            .filter { !EdenCommand.reservedNames.contains($0.name.lowercased()) }
    }

    func isAvailable(_ command: EdenCommand) -> Bool {
        switch command {
        case .model: !isRunning && installedChoices.count > 1
        case .effort: !isRunning && !model.efforts.isEmpty
        case .fast: !isRunning && fastTier != nil
        case .access: !isRunning
        case .new, .changes, .rename: thread != nil
        case .clear: !isRunning && thread?.sessionID != nil
        case .commit: !isRunning && thread?.worktree != nil
        case .stop: isRunning
        }
    }

    // MARK: Suggestions

    func suggestions(for text: String) -> SlashSuggestions {
        guard let query = SlashQuery(text) else { return SlashSuggestions() }
        guard let argument = query.argument else {
            return SlashSuggestions(items: commandItems(matching: query.name.lowercased()))
        }
        if let command = EdenCommand.named(query.name), isAvailable(command) {
            if command.argument == .choice {
                return SlashSuggestions(items: valueItems(for: command, matching: argument))
            }
            return SlashSuggestions(hint: item(for: command))
        }
        if let command = agentCommands.first(where: { $0.name == query.name || $0.aliases.contains(query.name) }) {
            return SlashSuggestions(hint: item(for: command))
        }
        return SlashSuggestions()
    }

    /// Eden's commands, then the agent's. Within each, an exact name comes
    /// first, then names that start with what was typed, then names that contain it.
    private func commandItems(matching typed: String) -> [SlashItem] {
        func ranked<T>(_ candidates: [T], names: (T) -> [String], item: (T) -> SlashItem) -> [SlashItem] {
            SlashContext.ranked(candidates, typed, names: names).map(item)
        }
        let eden = ranked(EdenCommand.allCases.filter(isAvailable), names: { [$0.rawValue] + $0.aliases }, item: item(for:))
        // Plugin commands are "plugin:skill"; typing just the skill's name finds them too.
        let agent = ranked(agentCommands, names: { command in
            let name = command.name.lowercased()
            return [name, String(name.split(separator: ":").last ?? "")] + command.aliases
        }, item: item(for:))
        return eden + agent
    }

    private func item(for command: EdenCommand) -> SlashItem {
        SlashItem(
            id: "eden:\(command.rawValue)",
            section: "Eden",
            symbol: command.symbol,
            title: "/\(command.rawValue)",
            hint: command.argumentHint,
            detail: detail(for: command),
            isCurrent: command == .fast && serviceTier != nil && serviceTier == fastTier?.id,
            action: .command(command)
        )
    }

    private func item(for command: AgentCommand) -> SlashItem {
        SlashItem(
            id: "agent:\(command.name)",
            section: model.provider,
            brand: model.agent.cliIcon,
            title: "/\(command.name)",
            hint: command.argumentHint,
            detail: command.detail,
            action: .agent(command)
        )
    }

    private func detail(for command: EdenCommand) -> String {
        switch command {
        case .model: return "Switch models (now \(model.name))"
        case .effort: return "Set reasoning effort (now \(AgentKind.effortLabel(effort ?? model.defaultEffort)))"
        case .fast:
            guard let tier = fastTier else { return "" }
            return serviceTier == tier.id ? "Turn off \(tier.name)" : "\(tier.name): \(tier.detail)"
        case .access: return "Set what the agent can do without asking (now \(access.label))"
        case .new: return "Start a new chat"
        case .clear: return "Start a fresh session in this worktree, keeping its changes"
        case .changes: return app.isShowing(.changes) ? "Hide Changes" : "Show Changes"
        case .commit: return "Commit all changes on \(thread?.branch ?? "this branch")"
        case .rename: return "Rename this session"
        case .stop: return "Stop \(model.name)"
        }
    }

    /// The choices for a command's argument, filtered by what's been typed.
    private func valueItems(for command: EdenCommand, matching typed: String) -> [SlashItem] {
        var items: [(item: SlashItem, value: String)] = []
        switch command {
        case .model:
            let pool = installedChoices.filter { !$0.isLegacy } + installedChoices.filter(\.isLegacy)
            items = pool.map { choice in
                let item = SlashItem(
                    id: "model:\(choice.id)",
                    section: choice.isLegacy ? "Legacy Models" : choice.provider,
                    brand: choice.agent.modelIcon,
                    title: choice.name,
                    detail: choice.detail,
                    isCurrent: choice == model,
                    action: .value(.model, choice.id)
                )
                return (item, choice.id)
            }
        case .effort:
            items = model.efforts.map { level in
                let item = SlashItem(
                    id: "effort:\(level)",
                    section: "Reasoning",
                    title: AgentKind.effortLabel(level),
                    badge: level == model.defaultEffort ? "Default" : nil,
                    isCurrent: (effort ?? model.defaultEffort) == level,
                    action: .value(.effort, level)
                )
                return (item, level)
            }
        case .access:
            items = AccessMode.allCases.map { mode in
                let item = SlashItem(
                    id: "access:\(mode.rawValue)",
                    section: "Access",
                    symbol: mode.symbol,
                    title: mode.label,
                    detail: mode.detail,
                    isCurrent: mode == access,
                    action: .value(.access, mode.rawValue)
                )
                return (item, mode.rawValue)
            }
        default:
            break
        }
        return SlashContext.ranked(items, typed.lowercased(), names: { [$0.item.title.lowercased(), $0.value.lowercased()] }).map(\.item)
    }

    /// Candidates whose names match what was typed: exact matches first, then
    /// prefixes, then substrings, each group in its original order. `typed` is lowercased.
    private static func ranked<T>(_ candidates: [T], _ typed: String, names: (T) -> [String]) -> [T] {
        guard !typed.isEmpty else { return candidates }
        func rank(_ names: [String]) -> Int? {
            if names.contains(typed) { return 0 }
            if names.contains(where: { $0.hasPrefix(typed) }) { return 1 }
            if names.contains(where: { $0.contains(typed) }) { return 2 }
            return nil
        }
        let scored = candidates.compactMap { candidate in rank(names(candidate)).map { (rank: $0, candidate: candidate) } }
        return (0...2).flatMap { level in scored.filter { $0.rank == level }.map(\.candidate) }
    }

    // MARK: Running

    /// Carries out a picked row and returns the composer's new text. Commands
    /// that need an argument fill in their name and wait for it; `send` gets an
    /// agent command that's ready to go. With `complete` (Tab), a row only
    /// fills in its name.
    func accept(_ item: SlashItem, complete: Bool, send: (String) -> Void) -> String {
        switch item.action {
        case .command(let command):
            if complete || command.argument != .none { return "/\(command.rawValue) " }
            perform(command, argument: "")
            return ""
        case .value(let command, let value):
            return perform(command, argument: value) ? "" : "/\(command.rawValue) "
        case .agent(let command):
            if complete || command.needsArgument { return "/\(command.name) " }
            send("/\(command.name)")
            return ""
        }
    }

    /// Runs typed text if it names one of Eden's commands. Anything else,
    /// including the agent's own commands, goes to the agent unchanged.
    func run(_ text: String) -> Outcome {
        guard let query = SlashQuery(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let command = EdenCommand.named(query.name)
        else { return .notCommand }
        guard isAvailable(command), perform(command, argument: query.argument ?? "") else { return .invalid }
        return .done
    }

    @discardableResult
    private func perform(_ command: EdenCommand, argument: String) -> Bool {
        switch command {
        case .model:
            guard let choice = pick(installedChoices, argument, names: { [$0.id, $0.name] })
                ?? installedChoices.first(where: { !argument.isEmpty && $0.name.localizedCaseInsensitiveContains(argument) })
            else { return false }
            model = choice
        case .effort:
            guard let level = pick(model.efforts, argument, names: { [$0, AgentKind.effortLabel($0)] }) else { return false }
            effort = level
        case .fast:
            guard let tier = fastTier else { return false }
            serviceTier = serviceTier == tier.id ? nil : tier.id
        case .access:
            guard let mode = pick(AccessMode.allCases, argument, names: { [$0.rawValue, $0.label] }) else { return false }
            access = mode
        case .new:
            app.newChat(in: repo)
        case .clear:
            guard let thread else { return false }
            thread.sessionID = nil
            thread.append(.note("Context cleared. The next message starts a fresh session in this worktree."))
        case .changes:
            app.togglePanel(.changes)
        case .commit:
            guard let thread, !argument.isEmpty else { return false }
            Task {
                do {
                    thread.append(.note(try await thread.commit(message: argument)))
                } catch {
                    thread.append(.error(error.localizedDescription))
                }
            }
        case .rename:
            guard let thread, !argument.isEmpty else { return false }
            thread.title = argument
        case .stop:
            thread?.stop()
        }
        return true
    }

    /// An exact name match, else the first name that starts with the argument.
    private func pick<T>(_ options: [T], _ argument: String, names: (T) -> [String]) -> T? {
        let typed = argument.lowercased()
        guard !typed.isEmpty else { return nil }
        return options.first { names($0).contains { $0.lowercased() == typed } }
            ?? options.first { names($0).contains { $0.lowercased().hasPrefix(typed) } }
    }
}

// MARK: Claude Code

/// Claude Code lists its commands and skills, with descriptions, in reply to
/// the `initialize` request the Agent SDK sends. It answers without calling a
/// model or saving a session, in under a second. Codex has no headless
/// equivalent, so OpenAI models get Eden's commands only.
enum ClaudeCommands {
    private static let terminalOnlyKey = "claudeTerminalOnlyCommands"

    private static let skillNamesKey = "claudeSkillNames"

    /// Which of the commands are skills, as Claude Code's latest init event
    /// listed them. Empty until the first turn; until then every command counts.
    static var skillNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: skillNamesKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: skillNamesKey) }
    }

    /// Commands that only work in Claude Code's terminal UI, as its latest init event listed them.
    static var terminalOnly: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: terminalOnlyKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: terminalOnlyKey) }
    }

    @MainActor
    static func load(in folder: URL) async -> [AgentCommand] {
        guard let response = await initialize(in: folder) else { return [] }
        let hidden = terminalOnly
        return (response["commands"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String, !name.hasPrefix("__"), !hidden.contains(name) else { return nil }
            // Skill descriptions run long; the menu shows their first line.
            let detail = (entry["description"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return AgentCommand(
                name: name,
                detail: detail,
                argumentHint: entry["argumentHint"] as? String ?? "",
                aliases: entry["aliases"] as? [String] ?? []
            )
        }
    }

    /// Claude Code's reply to `initialize`: its commands, models, and the
    /// account it's signed in to. Nil if Claude Code isn't installed or didn't answer.
    @MainActor
    static func initialize(in folder: URL) async -> [String: Any]? {
        guard let executable = Shell.which(AgentKind.claude.binary) else { return nil }
        let runner = AgentRunner(
            executable: executable,
            // Only your own settings: a freshly cloned repository's hooks shouldn't
            // run just because Eden asked what commands it offers.
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--setting-sources", "user"],
            cwd: folder
        )
        let request = #"{"type":"control_request","request_id":"eden-initialize","request":{"subtype":"initialize"}}"# + "\n"
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            runner.terminate()
        }
        defer { timeout.cancel() }

        var response: [String: Any]?
        _ = try? await runner.run(prompt: request) { event in
            guard event["type"] as? String == "control_response",
                  let reply = event["response"] as? [String: Any]
            else { return }
            response = reply["response"] as? [String: Any]
        }
        if let models = response?["models"] as? [[String: Any]], !models.isEmpty { ClaudeModelCache.save(models) }
        return response
    }
}
