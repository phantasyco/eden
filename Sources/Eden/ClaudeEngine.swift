import Foundation

/// How a session drives Claude Code: one long-lived process per session (see
/// AgentProcess), turns that end when Claude Code says so, streamed text, and
/// the approvals and questions it sends back. The turn bookkeeping, streaming,
/// and answers here serve Codex too (see CodexEngine.swift).
extension AgentThread {
    // MARK: Session

    /// Whether this thread asks for the 1M-token context window.
    var usesLongContext: Bool {
        catalogModel.longContext && (longContext ?? catalogModel.longContextByDefault)
    }

    /// Everything the process is started with. Changing any of it between
    /// turns starts a new process that resumes the same session.
    private var claudeConfiguration: String {
        [modelOverride ?? "", usesLongContext ? "1m" : "", effort ?? "", serviceTier ?? "", access.rawValue]
            .joined(separator: "|")
    }

    func startClaudeTurn(_ prompt: String, in folder: URL) throws {
        idleReaper?.cancel()
        try claudeSession(in: folder).sendUser(prompt)
    }

    private func claudeSession(in folder: URL) throws -> ClaudeSession {
        if let session, session.isAlive, session.configuration == claudeConfiguration { return session }
        session?.terminate()
        let fresh: ClaudeSession
        if repo.machine.isLocal {
            let (executable, arguments) = try command()
            fresh = ClaudeSession(executable: executable, arguments: arguments, cwd: folder, configuration: claudeConfiguration)
        } else {
            // On another machine: the same command line, run there over SSH.
            let remote = repo.machine.command("claude", claudeArguments(), in: folder.path)
            fresh = ClaudeSession(executable: remote.executable, arguments: remote.arguments,
                                  cwd: FileManager.default.homeDirectoryForCurrentUser, configuration: claudeConfiguration)
        }
        sessionCostBase = costUSD
        // Events from a process this thread has moved on from are dropped.
        try fresh.start(
            onEvent: { [weak self, weak fresh] event in
                guard let self, let fresh, self.session === fresh else { return }
                ClaudeEvents.handle(event, in: self)
            },
            onExit: { [weak self, weak fresh] status, stderr in
                guard let self, let fresh, self.session === fresh else { return }
                self.claudeExited(status: status, stderr: stderr)
            }
        )
        session = fresh
        return fresh
    }

    /// Ends the agent's process, as when Eden quits or the session is removed
    /// or archived. The conversation itself stays resumable.
    func closeSession() {
        idleReaper?.cancel()
        session?.terminate()
        session = nil
        codex?.terminate()
        codex?.failPending()
        codex = nil
        codexTurnID = nil
        acp?.terminate()
        acp?.failPending()
        acp = nil
        cursor?.terminate()
        cursor = nil
        backgroundAgents = []
        requests = []
    }

    /// An idle process costs memory, not money, but a day of sessions adds up.
    /// After half an hour without a turn it goes; the next message resumes.
    func scheduleIdleReaper() {
        idleReaper?.cancel()
        idleReaper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            guard let self, !Task.isCancelled, !self.isRunning, self.backgroundAgents.isEmpty else { return }
            self.closeSession()
        }
    }

    // MARK: Turns

    /// Interrupt asks Claude Code to stop the turn and keeps the process. If
    /// it hasn't stopped within a few seconds, the process goes instead.
    func interruptClaude(_ session: ClaudeSession) {
        requests = []
        session.interrupt()
        interruptFallback?.cancel()
        interruptFallback = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.isRunning, self.stopRequested else { return }
            session?.terminate()
        }
    }

    /// Claude Code started a turn nobody sent, like a background subagent
    /// reporting back after the last turn ended.
    func beginUnsolicitedTurn() {
        guard !isRunning else { return }
        idleReaper?.cancel()
        turn += 1
        turnError = nil
        stopRequested = false
        turnStartedAt = Date()
        updatedAt = Date()
        state = .running
    }

    /// A turn ended, for any agent: settle what's running, then Stopped,
    /// Failed, or Finished (which sends the next queued message).
    func finishTurn(error: String?) {
        guard isRunning else { return }
        flushStream()
        interruptFallback?.cancel()
        requests = []
        updatedAt = Date()
        lastTurnDuration = turnStartedAt.map { Date().timeIntervalSince($0) }
        settleRunningTools()
        if stopRequested {
            finishStopped()
        } else if let error {
            state = .failed(error)
        } else {
            state = .finished
        }
        stopRequested = false
        scheduleIdleReaper()
        if case .finished = state { sendNextQueued() }
        Task { await refreshDiff() }
    }

    private func claudeExited(status: Int32, stderr: [String]) {
        session = nil
        requests = []
        backgroundAgents = []
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

    // MARK: Streaming

    /// A text block started: it gets a transcript item right away, filled as text arrives.
    func startStreamingText(message: String, index: Int) {
        let id = "\(message)-\(index)"
        append(.assistant(""), id: id)
        streamingBlocks[message, default: []].append(id)
    }

    func appendStreamedText(_ text: String, message: String, index: Int) {
        appendStreamed(text, to: "\(message)-\(index)")
    }

    /// Adds streamed text to an assistant or thought item, shown in the next batch.
    func appendStreamed(_ text: String, to id: String) {
        guard item(id) != nil else { return }
        streamBuffer[id, default: ""] += text
        guard streamFlush == nil else { return }
        streamFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.flushStream()
        }
    }

    func flushStream() {
        streamFlush?.cancel()
        streamFlush = nil
        for (id, text) in streamBuffer {
            switch item(id)?.kind {
            case .assistant(let shown): upsert(id, .assistant(shown + text))
            case .thought(let shown): upsert(id, .thought(shown + text))
            default: break
            }
        }
        streamBuffer = [:]
    }

    /// The whole text of a block, which replaces what streamed in. Empty
    /// blocks leave no trace.
    func finishText(_ text: String, message: String) {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if var pending = streamingBlocks[message], !pending.isEmpty {
            let id = pending.removeFirst()
            streamingBlocks[message] = pending.isEmpty ? nil : pending
            streamBuffer[id] = nil
            if blank { removeItem(id) } else { upsert(id, .assistant(text)) }
        } else if !blank {
            append(.assistant(text))
        }
    }

    // MARK: Approvals and questions

    func receivePermissionRequest(_ request: [String: Any], id: String) {
        let tool = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let suggestions = request["permission_suggestions"] as? [Any] ?? []
        if tool == "AskUserQuestion" {
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { entry -> AgentQuestion? in
                guard let question = entry["question"] as? String else { return nil }
                let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return AgentQuestion.Option(label: label, detail: option["description"] as? String ?? "")
                }
                return AgentQuestion(key: question, question: question, header: entry["header"] as? String ?? "",
                                     options: options, multiSelect: entry["multiSelect"] as? Bool ?? false)
            }
            requests.append(AgentRequest(id: id, kind: .questions(questions), input: input, suggestions: []))
        } else {
            let summary = ClaudeEvents.summary(tool, input, cwd: worktree)
            requests.append(AgentRequest(id: id, kind: .approval(tool: tool, summary: summary), input: input, suggestions: suggestions))
        }
    }

    /// Lets the tool run. "Always" also applies the rule the agent suggested
    /// (Claude Code) or allows it for the rest of the session (Codex).
    func approve(_ request: AgentRequest, always: Bool = false) {
        switch request.origin {
        case .claude:
            var response: [String: Any] = ["behavior": "allow", "updatedInput": request.input]
            if always, !request.suggestions.isEmpty { response["updatedPermissions"] = request.suggestions }
            reply(to: request, claude: response)
        case .codex(_, let method):
            if method.contains("permissions") {
                reply(to: request, codex: ["permissions": request.input["permissions"] ?? [:], "scope": always ? "session" : "turn"])
            } else {
                reply(to: request, codex: ["decision": always ? "acceptForSession" : "accept"])
            }
        case .acp:
            reply(to: request, acpChoosing: always ? ["allow_always", "allow_once"] : ["allow_once", "allow_always"])
        }
    }

    func deny(_ request: AgentRequest) {
        switch request.origin {
        case .claude:
            reply(to: request, claude: ["behavior": "deny", "message": "The user declined this. Ask them how to proceed if you need it."])
        case .codex(_, let method):
            if method.contains("permissions") {
                reply(to: request, codex: ["permissions": [String: Any]()])
            } else if method.contains("requestUserInput") {
                reply(to: request, codex: ["answers": [String: Any]()])
            } else {
                reply(to: request, codex: ["decision": "decline"])
            }
        case .acp:
            reply(to: request, acpChoosing: ["reject_once", "reject_always"])
        }
    }

    /// Answers by each question's key: its text for Claude Code's
    /// AskUserQuestion, its id for Codex. Several choices for one question
    /// are joined with commas.
    func answer(_ request: AgentRequest, with answers: [String: String]) {
        switch request.origin {
        case .claude:
            var input = request.input
            input["answers"] = answers
            reply(to: request, claude: ["behavior": "allow", "updatedInput": input])
        case .codex:
            reply(to: request, codex: ["answers": answers.mapValues { ["answers": [$0]] }])
        case .acp:
            // ACP agents only ask for approvals.
            reply(to: request, acpChoosing: ["reject_once"])
        }
    }

    private func reply(to request: AgentRequest, claude response: [String: Any]) {
        requests.removeAll { $0.id == request.id }
        session?.respond(to: request.id, with: response)
    }

    /// Picks the first of the agent's options with one of these kinds, in order.
    private func reply(to request: AgentRequest, acpChoosing kinds: [String]) {
        requests.removeAll { $0.id == request.id }
        guard case .acp(let rpcID, let options) = request.origin else { return }
        let option = kinds.lazy.compactMap { kind in options.first { $0["kind"] as? String == kind } }.first
        if let id = option?["optionId"] as? String {
            acp?.reply(to: rpcID, result: ["outcome": ["outcome": "selected", "optionId": id]])
        } else {
            acp?.reply(to: rpcID, result: ["outcome": ["outcome": "cancelled"]])
        }
    }

    private func reply(to request: AgentRequest, codex result: [String: Any]) {
        requests.removeAll { $0.id == request.id }
        if case .codex(let rpcID, _) = request.origin { codex?.reply(to: rpcID, result: result) }
    }
}
