import Foundation

/// How a session drives Grok and OpenCode: the Agent Client Protocol, with
/// one long-lived process per session (`grok agent stdio`, `opencode acp`).
/// A turn is one `session/prompt` request and ends when it returns. Text, tool
/// calls, plans, and context usage arrive as `session/update` notifications,
/// and the agent asks for approval with `session/request_permission`. The
/// model and reasoning are session options, set before each turn, so changing
/// them doesn't need a new process.
extension AgentThread {
    /// What the process is started with. Grok only takes Full Access as a flag.
    private var acpConfiguration: String {
        agent == .grok && effectiveAccess == .full ? "always-approve" : ""
    }

    private var acpArguments: [String] {
        switch agent {
        case .grok: ["agent"] + (effectiveAccess == .full ? ["--always-approve"] : []) + ["stdio"]
        default: ["acp"]
        }
    }

    func startACPTurn(_ prompt: String, images: [String], in folder: URL) async throws {
        idleReaper?.cancel()
        let session = try await acpSession(in: folder)
        guard let sessionID else { throw EdenError(message: "\(agent.displayName) didn't start a session.") }
        await applyACPOptions(session, sessionID: sessionID)
        if agent == .grok, let window = catalogModel.contextWindow { contextWindow = window }

        var blocks: [[String: Any]] = [["type": "text", "text": prompt]]
        if acpImages, repo.machine.isLocal {
            for image in images {
                let url = folder.appendingPathComponent(image)
                guard let data = try? Data(contentsOf: url), data.count < 8_000_000 else { continue }
                let type = url.pathExtension.lowercased() == "jpg" ? "jpeg" : url.pathExtension.lowercased()
                blocks.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/\(type)"])
            }
        }
        acpMessage = nil
        // The turn runs until the prompt request returns; its events fill the transcript meanwhile.
        Task { [weak self, weak session] in
            guard let session else { return }
            do {
                let result = try await session.request("session/prompt", ["sessionId": sessionID, "prompt": blocks])
                guard let self, self.acp === session else { return }
                self.acpTurnEnded(result)
            } catch {
                // A process that ended says why itself (acpExited).
                guard let self, self.acp === session, session.isAlive, self.isRunning else { return }
                self.endACPMessage()
                self.append(.error(error.localizedDescription))
                self.finishTurn(error: error.localizedDescription)
            }
        }
    }

    private func acpTurnEnded(_ result: [String: Any]) {
        endACPMessage()
        // Grok says how much context its last reply used.
        if let used = (result["_meta"] as? [String: Any])?["totalTokens"] as? Int, used > 0 { contextUsed = used }
        switch result["stopReason"] as? String {
        case "cancelled":
            stopRequested = true
            finishTurn(error: nil)
        case "refusal":
            let message = "\(modelName) declined to continue."
            append(.error(message))
            finishTurn(error: message)
        case "max_tokens":
            append(.note("\(modelName) reached its output limit for one reply."))
            finishTurn(error: nil)
        case "max_turn_requests":
            append(.note("\(modelName) reached its step limit for one turn."))
            finishTurn(error: nil)
        default:
            finishTurn(error: nil)
        }
    }

    /// The running process, or a new one with this session's conversation
    /// started, resumed, or forked.
    private func acpSession(in folder: URL) async throws -> ACPSession {
        if let acp, acp.isAlive, acp.configuration == acpConfiguration { return acp }
        if let acp {
            self.acp = nil
            acp.terminate()
            acp.failPending()
        }
        let fresh: ACPSession
        if repo.machine.isLocal {
            guard let executable = Shell.which(agent.binary) else {
                throw EdenError(message: "Couldn't find `\(agent.binary)` on your PATH. Install \(agent.displayName) first.")
            }
            fresh = ACPSession(agent: agent, executable: executable, arguments: acpArguments, cwd: folder, configuration: acpConfiguration)
        } else {
            // On another machine: its own agent, reached over SSH.
            let remote = repo.machine.command(agent.binary, acpArguments, in: folder.path)
            fresh = ACPSession(agent: agent, executable: remote.executable, arguments: remote.arguments,
                               cwd: FileManager.default.homeDirectoryForCurrentUser, configuration: acpConfiguration)
        }
        try fresh.start(
            onEvent: { [weak self, weak fresh] message in
                guard let self, let fresh, self.acp === fresh, !fresh.settle(message) else { return }
                ACPEvents.handle(message, in: self)
            },
            onExit: { [weak self, weak fresh] status, stderr in
                guard let self, let fresh, self.acp === fresh else { return }
                self.acpExited(status: status, stderr: stderr)
            }
        )
        acp = fresh
        acpOptions = []
        acpMessage = nil

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let initialized = try await fresh.request("initialize", [
            "protocolVersion": 1,
            // Eden doesn't hand out its own file system or terminals; the agent uses its own tools.
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "eden", "title": "Eden", "version": version],
        ])
        let capabilities = initialized["agentCapabilities"] as? [String: Any] ?? [:]
        let sessions = capabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        acpImages = (capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true

        let params: [String: Any] = ["cwd": folder.path, "mcpServers": [Any]()]
        if let existing = sessionID {
            do {
                let resumed = params.merging(["sessionId": existing]) { $1 }
                let result: [String: Any]
                if forkPending, sessions["fork"] != nil {
                    result = try await fresh.request("session/fork", resumed)
                } else if sessions["resume"] != nil {
                    result = try await fresh.request("session/resume", resumed)
                } else if capabilities["loadSession"] as? Bool == true {
                    // Loading replays the conversation as updates; the transcript already has it.
                    acpReplaying = true
                    defer { acpReplaying = false }
                    result = try await fresh.request("session/load", resumed)
                } else {
                    throw EdenError(message: "\(agent.displayName) can't reopen sessions.")
                }
                if let id = result["sessionId"] as? String { sessionID = id }
                acpOptions = result["configOptions"] as? [[String: Any]] ?? []
                // A reopened session's running cost includes turns Eden already counted.
                acpCost = nil
                forkPending = false
                return fresh
            } catch {
                forkPending = false
                append(.note("\(agent.displayName) couldn't pick up the earlier conversation, so this message starts a new one."))
            }
        }
        let result = try await fresh.request("session/new", params)
        sessionID = result["sessionId"] as? String
        acpOptions = result["configOptions"] as? [[String: Any]] ?? []
        acpCost = 0
        return fresh
    }

    /// Picks the session's model, then its reasoning level: a model's levels
    /// only show up once the model is chosen.
    private func applyACPOptions(_ session: ACPSession, sessionID: String) async {
        let chosen = catalogModel
        if modelOverride != nil, let model = chosen.cliID, !model.isEmpty {
            await setACPOption("model", to: model, session, sessionID: sessionID)
        }
        if let effort, chosen.efforts.contains(effort) {
            await setACPOption("thought_level", to: effort, session, sessionID: sessionID)
        }
    }

    private func setACPOption(_ category: String, to value: String, _ session: ACPSession, sessionID: String) async {
        guard let option = acpOptions.first(where: { $0["category"] as? String == category }),
              let id = option["id"] as? String,
              option["currentValue"] as? String != value
        else { return }
        // Choices can come in groups ("Google", "OpenRouter"), each with its own list.
        let choices = (option["options"] as? [[String: Any]] ?? []).flatMap { $0["options"] as? [[String: Any]] ?? [$0] }
        guard choices.contains(where: { $0["value"] as? String == value }) else {
            if category == "model" { append(.note("\(agent.displayName) doesn't offer \(modelName) right now, so it kept its current model.")) }
            return
        }
        do {
            let result = try await session.request("session/set_config_option", ["sessionId": sessionID, "configId": id, "value": value])
            if let options = result["configOptions"] as? [[String: Any]] { acpOptions = options }
        } catch {
            append(.note("\(agent.displayName) couldn't switch \(category == "model" ? "to \(modelName)" : "reasoning"): \(error.localizedDescription)"))
        }
    }

    /// Stop: ACP cancels with a notification, and every approval still waiting
    /// is answered "cancelled". The prompt request then returns `cancelled`;
    /// if it doesn't within a few seconds, the process goes instead.
    func interruptACP(_ session: ACPSession) {
        for request in requests {
            if case .acp(let rpcID, _) = request.origin { session.reply(to: rpcID, result: ["outcome": ["outcome": "cancelled"]]) }
        }
        requests = []
        guard let sessionID else {
            session.terminate()
            return
        }
        session.notify("session/cancel", ["sessionId": sessionID])
        interruptFallback?.cancel()
        interruptFallback = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.isRunning, self.stopRequested else { return }
            session?.terminate()
        }
    }

    /// Text that arrives after a tool call starts a new message, and a new thought.
    func endACPMessage() {
        flushStream()
        if let id = acpMessage, let item = item(id), case .assistant(let text) = item.kind,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeItem(id)
        }
        acpMessage = nil
        acpThought = nil
    }

    /// OpenCode reports the session's running cost; Eden adds what's new.
    func addACPCost(total: Double) {
        if let seen = acpCost { costUSD += max(0, total - seen) }
        acpCost = total
    }

    /// Whether your access mode answers this approval without asking you.
    func acpAllows(kind: String?) -> Bool {
        switch effectiveAccess {
        case .full: true
        case .acceptEdits, .auto: ["read", "search", "think", "edit"].contains(kind ?? "")
        case .supervised: ["read", "search", "think"].contains(kind ?? "")
        }
    }

    private func acpExited(status: Int32, stderr: [String]) {
        acp?.failPending()
        acp = nil
        acpMessage = nil
        requests = []
        guard isRunning else { return }
        if stopRequested {
            finishTurn(error: nil)
            return
        }
        let detail = stderr.suffix(6).joined(separator: "\n")
        let message = detail.isEmpty ? "\(modelName) stopped unexpectedly (exit status \(status))." : detail
        append(.error(message))
        finishTurn(error: message)
    }
}

/// ACP notifications and requests for one session, plus the few of Grok's
/// own extensions worth showing (retries and cost).
enum ACPEvents {
    @MainActor
    static func handle(_ message: [String: Any], in thread: AgentThread) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let rpcID = message["id"] {
            request(method, params, rpcID: rpcID, in: thread)
            return
        }
        switch method {
        case "session/update":
            guard !thread.acpReplaying, let update = params["update"] as? [String: Any] else { return }
            handle(update: update, in: thread)
        case "_x.ai/session_notification":
            guard let update = params["update"] as? [String: Any] else { return }
            grok(update, in: thread)
        default:
            break
        }
    }

    @MainActor
    private static func handle(update: [String: Any], in thread: AgentThread) {
        switch update["sessionUpdate"] as? String {
        case "agent_thought_chunk":
            guard thread.isRunning, let text = (update["content"] as? [String: Any])?["text"] as? String else { return }
            if thread.acpMessage != nil { thread.endACPMessage() }
            let id: String
            if let current = thread.acpThought {
                id = current
            } else {
                id = UUID().uuidString
                thread.acpThought = id
                thread.append(.thought(""), id: id)
            }
            thread.appendStreamed(text, to: id)

        case "agent_message_chunk":
            guard thread.isRunning, let text = (update["content"] as? [String: Any])?["text"] as? String else { return }
            thread.acpThought = nil
            let id: String
            if let current = thread.acpMessage {
                id = current
            } else {
                id = UUID().uuidString
                thread.acpMessage = id
                thread.append(.assistant(""), id: id)
            }
            thread.appendStreamed(text, to: id)

        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            thread.endACPMessage()
            var call = thread.toolCall(id) ?? ToolCall(name: "Tool", detail: "")
            apply(update, to: &call, cwd: thread.worktree)
            thread.upsert(id, .tool(call))
            if call.status != .running { Task { await thread.refreshDiff() } }

        case "plan":
            let lines = (update["entries"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let content = entry["content"] as? String else { return nil }
                switch entry["status"] as? String {
                case "completed": return "✓ " + content
                case "in_progress": return "→ " + content
                default: return "○ " + content
                }
            }
            if !lines.isEmpty { thread.upsert("plan-\(thread.turn)", .note("Plan\n" + lines.joined(separator: "\n"))) }

        case "usage_update":
            if let used = update["used"] as? Int, used > 0 { thread.contextUsed = used }
            if let size = update["size"] as? Int, size > 0 { thread.contextWindow = size }
            if let amount = (update["cost"] as? [String: Any])?["amount"] as? Double { thread.addACPCost(total: amount) }

        case "config_option_update":
            if let options = update["configOptions"] as? [[String: Any]] { thread.acpOptions = options }

        default:
            break
        }
    }

    /// Grok's retries (a rate limit on its free tier, mostly) and each turn's cost.
    @MainActor
    private static func grok(_ update: [String: Any], in thread: AgentThread) {
        switch update["sessionUpdate"] as? String {
        case "retry_state":
            guard thread.isRunning, update["type"] as? String == "retrying" else { return }
            let attempt = update["attempt"] as? Int ?? 1
            let limit = update["max_retries"] as? Int
            let count = limit.map { "attempt \(attempt) of \($0)" } ?? "attempt \(attempt)"
            let why = update["error_type"] as? String == "rate_limited" ? "Grok is rate limited" : "Grok hit an error"
            thread.upsert("retry-\(thread.turn)", .note("\(why), so it's retrying (\(count))."))
        case "turn_completed":
            // xAI counts cost in ticks of a ten-billionth of a dollar.
            if let ticks = (update["usage"] as? [String: Any])?["costUsdTicks"] as? Double {
                thread.costUSD += ticks / 10_000_000_000
            }
        default:
            break
        }
    }

    /// Folds a tool call or its update into what the transcript shows: the
    /// kind names it, the input says what it touches, and the content is its output.
    static func apply(_ update: [String: Any], to call: inout ToolCall, cwd: URL?) {
        let kind = update["kind"] as? String
        let title = update["title"] as? String
        if let kind, let name = names[kind] { call.name = name }
        if call.name == "Tool", let title, !title.isEmpty { call.name = title }

        let input = update["rawInput"] as? [String: Any] ?? [:]
        let base = cwd.map { $0.path + "/" } ?? ""
        func relative(_ path: String) -> String { path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path }
        let locations = (update["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let detail = (input["command"] as? String)
            ?? (input["file_path"] as? String ?? input["filePath"] as? String ?? input["path"] as? String).map(relative)
            ?? (locations.isEmpty ? nil : locations.map(relative).joined(separator: ", "))
            ?? input["pattern"] as? String ?? input["query"] as? String ?? input["url"] as? String
        if let detail, !detail.isEmpty {
            call.detail = detail
        } else if call.detail.isEmpty, let title, title != call.name {
            call.detail = title
        }

        if let content = update["content"] as? [[String: Any]] {
            let output = content.compactMap { block -> String? in
                switch block["type"] as? String {
                case "content": return (block["content"] as? [String: Any])?["text"] as? String
                case "diff": return diff(block, relative: relative)
                default: return nil
                }
            }.joined(separator: "\n")
            // A command's description arrives as content before its output does.
            if !(call.name == "Shell" && output == input["description"] as? String) {
                call.output = output.utf8.count > 60_000 ? String(output.suffix(40_000)) : output
            }
        }

        switch update["status"] as? String {
        case "pending", "in_progress": call.status = .running
        case "completed": call.status = .done
        case "failed": call.status = .failed
        default: break
        }
    }

    private static let names = [
        "execute": "Shell", "edit": "Edit", "read": "Read", "search": "Search", "delete": "Delete",
        "move": "Move", "fetch": "Fetch", "think": "Think",
    ]

    /// An edit's old and new text as removed and added lines.
    private static func diff(_ block: [String: Any], relative: (String) -> String) -> String {
        let path = (block["path"] as? String).map(relative) ?? ""
        let old = (block["oldText"] as? String).map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        let new = (block["newText"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        return (["--- \(path)", "+++ \(path)"] + old.map { "-" + $0 } + new.map { "+" + $0 }).joined(separator: "\n")
    }

    /// The agent asking to use a tool. Your access mode answers the kinds it
    /// covers; anything else waits in the request panel.
    @MainActor
    private static func request(_ method: String, _ params: [String: Any], rpcID: Any, in thread: AgentThread) {
        guard method == "session/request_permission" else {
            thread.acp?.replyError(to: rpcID, message: "Eden doesn't handle \(method).")
            return
        }
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        var call = (toolCall["toolCallId"] as? String).flatMap { thread.toolCall($0) } ?? ToolCall(name: "Tool", detail: "")
        apply(toolCall, to: &call, cwd: thread.worktree)
        let kind = toolCall["kind"] as? String
        let tool = approvalNames[kind ?? ""] ?? call.name
        let request = AgentRequest(
            id: "acp-\(rpcID)",
            kind: .approval(tool: tool, summary: call.detail.isEmpty ? toolCall["title"] as? String ?? "" : call.detail),
            input: toolCall, suggestions: [],
            origin: .acp(rpcID: rpcID, options: params["options"] as? [[String: Any]] ?? [])
        )
        if thread.acpAllows(kind: kind) {
            thread.approve(request)
        } else {
            thread.requests.append(request)
        }
    }

    /// The names the request panel phrases ("wants to run a command").
    private static let approvalNames = [
        "execute": "Bash", "edit": "Edit", "delete": "Delete", "move": "Move", "fetch": "WebFetch", "read": "Read", "search": "Search",
    ]
}
