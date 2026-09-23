import Foundation

/// How a session drives Codex: its app-server, one per session, with the
/// conversation as a Codex thread. Turns start with `turn/start`, messages sent
/// while it works go in with `turn/steer`, and Stop is `turn/interrupt`. The
/// model, reasoning, and access travel with each turn, so changing them
/// doesn't need a new process.
extension AgentThread {
    /// Codex's approval policy, sandbox, and reviewer for this session's access.
    private var codexAccess: (approval: String, sandbox: [String: Any], mode: String, reviewer: String) {
        switch access {
        // Asks before anything that isn't known to be safe.
        case .supervised: ("untrusted", ["type": "workspaceWrite"], "workspace-write", "user")
        // Works freely in the workspace; asks to go outside it.
        case .acceptEdits: ("on-request", ["type": "workspaceWrite"], "workspace-write", "user")
        // The same, with Codex's own reviewer answering instead of you.
        case .auto: ("on-request", ["type": "workspaceWrite"], "workspace-write", "auto_review")
        case .full: ("never", ["type": "dangerFullAccess"], "danger-full-access", "user")
        }
    }

    func startCodexTurn(_ prompt: String, images: [String], in folder: URL) async throws {
        idleReaper?.cancel()
        let session = try await codexSession(in: folder)
        guard let threadID = sessionID else { throw EdenError(message: "Codex didn't start a session.") }
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in images { input.append(["type": "localImage", "path": folder.appendingPathComponent(image).path]) }
        let access = codexAccess
        var params: [String: Any] = [
            "threadId": threadID, "input": input, "summary": "auto",
            "approvalPolicy": access.approval, "approvalsReviewer": access.reviewer, "sandboxPolicy": access.sandbox,
        ]
        if let modelOverride { params["model"] = modelOverride }
        if let effort, catalogModel.efforts.contains(effort) { params["effort"] = effort }
        if let serviceTier { params["serviceTier"] = serviceTier }
        let result = try await session.request("turn/start", params)
        if let id = (result["turn"] as? [String: Any])?["id"] as? String { codexTurnID = id }
    }

    /// The running app-server, or a new one with this session's Codex thread
    /// started, resumed, or forked.
    private func codexSession(in folder: URL) async throws -> CodexSession {
        if let codex, codex.isAlive { return codex }
        let fresh: CodexSession
        if repo.machine.isLocal {
            guard let executable = Shell.which(AgentKind.codex.binary) else {
                throw EdenError(message: "Couldn't find `codex` on your PATH. Install \(AgentKind.codex.displayName) first.")
            }
            fresh = CodexSession(executable: executable, arguments: ["app-server"], cwd: folder, configuration: folder.path)
        } else {
            // On another machine: its own Codex, reached over SSH.
            let remote = repo.machine.command("codex", ["app-server"], in: folder.path)
            fresh = CodexSession(executable: remote.executable, arguments: remote.arguments,
                                 cwd: FileManager.default.homeDirectoryForCurrentUser, configuration: folder.path)
        }
        try fresh.start(
            onEvent: { [weak self, weak fresh] message in
                guard let self, let fresh, self.codex === fresh, !fresh.settle(message) else { return }
                CodexEvents.handle(message, in: self)
            },
            onExit: { [weak self, weak fresh] status, stderr in
                guard let self, let fresh, self.codex === fresh else { return }
                self.codexExited(status: status, stderr: stderr)
            }
        )
        codex = fresh
        codexChildThreads = [:]

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        _ = try await fresh.request("initialize", [
            "clientInfo": ["name": "eden", "title": "Eden", "version": version],
            "capabilities": ["experimentalApi": true],
        ])
        fresh.notify("initialized")

        let access = codexAccess
        var params: [String: Any] = [
            "cwd": folder.path, "approvalPolicy": access.approval, "sandbox": access.mode, "approvalsReviewer": access.reviewer,
        ]
        if let modelOverride { params["model"] = modelOverride }
        if let serviceTier { params["serviceTier"] = serviceTier }

        if let existing = sessionID {
            params["threadId"] = existing
            do {
                let method = forkPending ? "thread/fork" : "thread/resume"
                // Branching from an earlier turn forks through that turn only.
                if forkPending, let forkAnchor { params["lastTurnId"] = forkAnchor }
                let result = try await fresh.request(method, params)
                if let id = (result["thread"] as? [String: Any])?["id"] as? String { sessionID = id }
                forkPending = false
                forkAnchor = nil
                return fresh
            } catch {
                params["threadId"] = nil
                forkPending = false
                append(.note("Codex couldn't pick up the earlier conversation, so this message starts a new one."))
            }
        }
        let result = try await fresh.request("thread/start", params)
        sessionID = (result["thread"] as? [String: Any])?["id"] as? String
        return fresh
    }

    /// Stop: Codex ends the turn and says so with `turn/completed`. If that
    /// doesn't come within a few seconds, the process goes instead.
    func interruptCodex(_ session: CodexSession) {
        requests = []
        guard let threadID = sessionID, let turnID = codexTurnID else {
            session.terminate()
            return
        }
        Task { _ = try? await session.request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) }
        interruptFallback?.cancel()
        interruptFallback = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.isRunning, self.stopRequested else { return }
            session?.terminate()
        }
    }

    /// Sends a message into Codex's running turn. If the turn ended first,
    /// the message waits in the queue instead.
    func steerCodex(_ text: String, message: String, itemID: String) {
        guard let codex, let threadID = sessionID, let turnID = codexTurnID else { return }
        Task {
            do {
                _ = try await codex.request("turn/steer", [
                    "threadId": threadID, "expectedTurnId": turnID,
                    "input": [["type": "text", "text": message]],
                ])
            } catch {
                removeItem(itemID)
                enqueue(text)
            }
        }
    }

    private func codexExited(status: Int32, stderr: [String]) {
        codex?.failPending()
        codex = nil
        codexTurnID = nil
        requests = []
        for (id, run) in subagents where run.status == .running { subagents[id]?.status = .failed }
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

/// Codex app-server notifications and requests for one session. Items from
/// a subagent's own Codex thread go to that subagent's transcript.
enum CodexEvents {
    @MainActor
    static func handle(_ message: [String: Any], in thread: AgentThread) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let rpcID = message["id"] {
            request(method, params, rpcID: rpcID, in: thread)
            return
        }
        if let threadID = params["threadId"] as? String, threadID != thread.sessionID {
            if let parent = thread.codexChildThreads[threadID] { subagent(method, params, parent: parent, in: thread) }
            return
        }
        switch method {
        case "turn/started":
            thread.beginUnsolicitedTurn()
            if let id = (params["turn"] as? [String: Any])?["id"] as? String { thread.codexTurnID = id }

        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            handle(item: item, completed: method == "item/completed", in: thread)

        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            if thread.item(id) == nil { thread.append(.assistant(""), id: id) }
            thread.appendStreamed(delta, to: id)

        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String,
                  var call = thread.toolCall(id), call.status == .running
            else { return }
            call.output += delta
            if call.output.utf8.count > 60_000 { call.output = String(call.output.suffix(40_000)) }
            thread.upsert(id, .tool(call))

        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"] as? [String: Any]
            if let last = usage?["last"] as? [String: Any], let used = last["totalTokens"] as? Int, used > 0 {
                thread.contextUsed = used
            }
            if let window = usage?["modelContextWindow"] as? Int { thread.contextWindow = window }

        case "error":
            guard params["willRetry"] as? Bool != true else { return }
            let message = (params["error"] as? [String: Any])?["message"] as? String ?? "\(thread.modelName) reported an error"
            thread.append(.error(message))
            thread.turnError = message

        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            // A branch after this turn forks through it.
            if let id = turn["id"] as? String ?? thread.codexTurnID { thread.stampAnchor(id) }
            thread.codexTurnID = nil
            switch turn["status"] as? String {
            case "interrupted":
                thread.stopRequested = true
                thread.finishTurn(error: nil)
            case "failed":
                let message = (turn["error"] as? [String: Any])?["message"] as? String ?? thread.turnError ?? "\(thread.modelName) couldn't finish."
                if thread.turnError == nil { thread.append(.error(message)) }
                thread.finishTurn(error: message)
            default:
                thread.finishTurn(error: nil)
            }

        default:
            break
        }
    }

    @MainActor
    private static func handle(item: [String: Any], completed: Bool, in thread: AgentThread) {
        guard let id = item["id"] as? String else { return }
        switch item["type"] as? String {
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            if !completed {
                if thread.item(id) == nil { thread.append(.assistant(text), id: id) }
                return
            }
            thread.flushStream()
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                thread.removeItem(id)
            } else {
                thread.upsert(id, .assistant(text))
            }

        case "plan":
            if completed, let text = item["text"] as? String, !text.isEmpty { thread.upsert(id, .note("Plan\n" + text)) }

        case "reasoning":
            // The summaries Codex writes of its reasoning ("**Checking the docs**…").
            let summary = (item["summary"] as? [String] ?? []).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if completed, !summary.isEmpty { thread.upsert(id, .thought(summary)) }

        case "contextCompaction":
            if completed { thread.upsert(id, .note("Codex compacted the conversation to make room.")) }

        case "collabAgentToolCall":
            collab(item, id: id, completed: completed, in: thread)

        default:
            if var call = toolCall(for: item, cwd: thread.worktree) {
                // Output that streamed in stays when the final item has none.
                if let existing = thread.toolCall(id), call.output.isEmpty { call.output = existing.output }
                thread.upsert(id, .tool(call))
                if completed { Task { await thread.refreshDiff() } }
            }
        }
    }

    /// Codex's own tools as Eden shows them: a shell command, file edits, an
    /// MCP tool, or a web search.
    static func toolCall(for item: [String: Any], cwd: URL?) -> ToolCall? {
        switch item["type"] as? String {
        case "commandExecution":
            var call = ToolCall(name: "Shell", detail: unwrap(item["command"] as? String ?? ""))
            call.output = item["aggregatedOutput"] as? String ?? ""
            call.status = status(item["status"] as? String, exitCode: item["exitCode"] as? Int)
            return call
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let base = cwd.map { $0.path + "/" } ?? ""
            let paths = changes.compactMap { $0["path"] as? String }.map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : $0 }
            var call = ToolCall(name: "Edit", detail: paths.joined(separator: ", "))
            call.output = changes.compactMap { $0["diff"] as? String }.joined(separator: "\n")
            call.status = status(item["status"] as? String, exitCode: nil)
            return call
        case "mcpToolCall":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            var call = ToolCall(name: "MCP", detail: name)
            call.status = status(item["status"] as? String, exitCode: nil)
            if let error = item["error"] as? [String: Any] { call.output = error["message"] as? String ?? "" }
            return call
        case "webSearch":
            var call = ToolCall(name: "Web search", detail: item["query"] as? String ?? "")
            call.status = .done
            return call
        default:
            return nil
        }
    }

    private static func status(_ status: String?, exitCode: Int?) -> ToolCall.Status {
        switch status {
        case "inProgress", nil: return .running
        case "completed": return (exitCode ?? 0) == 0 ? .done : .failed
        default: return .failed
        }
    }

    /// A subagent Codex spawned: a card in the transcript, and its own thread's
    /// items routed to it from then on.
    @MainActor
    private static func collab(_ item: [String: Any], id: String, completed: Bool, in thread: AgentThread) {
        guard item["tool"] as? String == "spawnAgent" else { return }
        let prompt = item["prompt"] as? String ?? ""
        for child in item["receiverThreadIds"] as? [String] ?? [] { thread.codexChildThreads[child] = id }
        if thread.subagents[id] == nil {
            let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? "Subagent"
            thread.subagents[id] = SubagentRun(description: String(firstLine.prefix(80)), kind: item["model"] as? String, prompt: prompt)
        }
        let status: ToolCall.Status
        switch item["status"] as? String {
        case "inProgress", nil: status = .running
        case "completed": status = .done
        default: status = .failed
        }
        // Spawning returns at once; the subagent itself runs on.
        if !completed || status == .failed { thread.subagents[id]?.status = status }
        var call = ToolCall(name: "Agent", detail: thread.subagents[id]?.description ?? "Subagent")
        call.status = thread.subagents[id]?.status ?? status
        thread.upsert(id, .tool(call))
    }

    /// Items and turns from a subagent's own Codex thread.
    @MainActor
    private static func subagent(_ method: String, _ params: [String: Any], parent: String, in thread: AgentThread) {
        switch method {
        case "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return }
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                thread.subagents[parent]?.upsert(id, .assistant(text))
                thread.subagents[parent]?.summary = String(text.prefix(200))
            } else if let call = toolCall(for: item, cwd: thread.worktree) {
                thread.subagents[parent]?.upsert(id, .tool(call))
            }
        case "item/started":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String,
                  let call = toolCall(for: item, cwd: thread.worktree)
            else { return }
            thread.subagents[parent]?.upsert(id, .tool(call))
            thread.subagents[parent]?.activity = "\(call.name) \(call.detail)"
        case "turn/completed":
            let status = (params["turn"] as? [String: Any])?["status"] as? String
            let finished: ToolCall.Status = status == "completed" ? .done : .failed
            thread.subagents[parent]?.status = finished
            thread.subagents[parent]?.activity = nil
            if var call = thread.toolCall(parent) {
                call.status = finished
                thread.upsert(parent, .tool(call))
            }
        default:
            break
        }
    }

    /// Codex asking for something: an approval, or answers to its questions.
    @MainActor
    private static func request(_ method: String, _ params: [String: Any], rpcID: Any, in thread: AgentThread) {
        let key = "codex-\(rpcID)"
        let origin = AgentRequest.Origin.codex(rpcID: rpcID, method: method)
        switch method {
        case "item/commandExecution/requestApproval":
            var summary = unwrap(params["command"] as? String ?? "")
            if let reason = params["reason"] as? String, !reason.isEmpty { summary += summary.isEmpty ? reason : "\n\(reason)" }
            thread.requests.append(AgentRequest(id: key, kind: .approval(tool: "Bash", summary: summary), input: params, suggestions: [], origin: origin))
        case "item/fileChange/requestApproval":
            let summary = params["reason"] as? String ?? params["grantRoot"] as? String ?? ""
            thread.requests.append(AgentRequest(id: key, kind: .approval(tool: "Edit", summary: summary), input: params, suggestions: [], origin: origin))
        case "item/permissions/requestApproval":
            let summary = params["reason"] as? String ?? "More access than the sandbox allows"
            thread.requests.append(AgentRequest(id: key, kind: .approval(tool: "more access", summary: summary), input: params, suggestions: [], origin: origin))
        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { entry -> AgentQuestion? in
                guard let id = entry["id"] as? String, let question = entry["question"] as? String else { return nil }
                let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return AgentQuestion.Option(label: label, detail: option["description"] as? String ?? "")
                }
                return AgentQuestion(key: id, question: question, header: entry["header"] as? String ?? "", options: options, multiSelect: false)
            }
            thread.requests.append(AgentRequest(id: key, kind: .questions(questions), input: params, suggestions: [], origin: origin))
        default:
            thread.codex?.replyError(to: rpcID, message: "Eden doesn't handle \(method).")
        }
    }

    /// Codex wraps commands as `/bin/zsh -lc '...'` or `-lc "..."`; show just the command.
    static func unwrap(_ command: String) -> String {
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc "] where command.hasPrefix(shell) {
            let inner = command.dropFirst(shell.count)
            guard inner.count >= 2, let quote = inner.first, quote == "'" || quote == "\"", inner.last == quote else {
                return String(inner)
            }
            let body = String(inner.dropFirst().dropLast())
            guard quote == "\"" else { return body }
            return body.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return command
    }
}
