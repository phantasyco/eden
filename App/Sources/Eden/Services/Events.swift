import Foundation

/// Claude Code `--output-format stream-json` events from a thread's
/// long-lived process. Frames with a `parent_tool_use_id` belong to a
/// subagent and go to its own transcript.
enum ClaudeEvents {
    @MainActor
    static func handle(_ event: [String: Any], in thread: AgentThread) {
        let parent = event["parent_tool_use_id"] as? String
        switch event["type"] as? String {
        case "system":
            system(event, in: thread)

        case "stream_event" where parent == nil:
            stream(event["event"] as? [String: Any] ?? [:], in: thread)

        case "assistant":
            let message = event["message"] as? [String: Any] ?? [:]
            if let parent {
                subagentAssistant(message, parent: parent, in: thread)
                return
            }
            let messageID = message["id"] as? String ?? UUID().uuidString
            if let usage = message["usage"] as? [String: Any] {
                let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
                if used > 0 { thread.contextUsed = used }
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    thread.finishText(block["text"] as? String ?? "", message: messageID)
                case "thinking":
                    // Empty when the model's thinking isn't shown, only signed.
                    let text = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { thread.append(.thought(text)) }
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    thread.upsert(id, .tool(ToolCall(name: name, detail: summary(name, input, cwd: thread.worktree))))
                    if isAgentTool(name) {
                        thread.subagents[id] = SubagentRun(
                            description: input["description"] as? String ?? "Subagent",
                            kind: input["subagent_type"] as? String,
                            prompt: input["prompt"] as? String ?? ""
                        )
                    }
                default:
                    break
                }
            }
            // Where a branch after this message would pick the conversation up.
            if let uuid = event["uuid"] as? String { thread.stampAnchor(uuid) }

        case "user":
            let message = event["message"] as? [String: Any]
            for block in message?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let output = text(of: block["content"])
                let failed = block["is_error"] as? Bool ?? false
                if let parent {
                    guard var call = thread.subagents[parent]?.toolCall(id) else { continue }
                    call.output = output
                    call.status = failed ? .failed : .done
                    thread.subagents[parent]?.upsert(id, .tool(call))
                    if !failed { Task { await thread.refreshDiff() } }
                    continue
                }
                guard var call = thread.toolCall(id) else { continue }
                call.output = output
                // A background subagent's call returns at once; it's done when
                // the subagent reports back (see task_notification).
                if !thread.backgroundAgents.contains(id) {
                    call.status = failed ? .failed : .done
                    if !failed, thread.subagents[id] != nil { thread.subagents[id]?.status = .done }
                    if failed { thread.subagents[id]?.status = .failed }
                }
                thread.upsert(id, .tool(call))
                if call.status == .done { Task { await thread.refreshDiff() } }
            }

        case "control_request":
            guard let requestID = event["request_id"] as? String, let request = event["request"] as? [String: Any] else { return }
            if request["subtype"] as? String == "can_use_tool" {
                thread.receivePermissionRequest(request, id: requestID)
            } else {
                thread.session?.decline(requestID, reason: "Eden doesn't handle \(request["subtype"] as? String ?? "this request").")
            }

        case "result":
            thread.costUSD = thread.sessionCostBase + (event["total_cost_usd"] as? Double ?? 0)
            if let usage = event["modelUsage"] as? [String: [String: Any]] {
                let entry = thread.model.flatMap { usage[$0] } ?? usage.values.first
                if let window = entry?["contextWindow"] as? Int { thread.contextWindow = window }
            }
            // Messages that arrived too late for this turn start another one right away.
            if let queued = event["queued_turn_count"] as? Int, queued > 0 { return }
            var error: String?
            if event["is_error"] as? Bool == true, !thread.stopRequested {
                let message = event["result"] as? String ?? "\(thread.modelName) reported an error"
                thread.append(.error(message))
                error = message
            }
            thread.finishTurn(error: error)

        default:
            break
        }
    }

    @MainActor
    private static func system(_ event: [String: Any], in thread: AgentThread) {
        switch event["subtype"] as? String {
        case "init":
            thread.sessionID = event["session_id"] as? String ?? thread.sessionID
            // The fork's first message made its own session; from here on it resumes that one.
            thread.forkPending = false
            thread.forkAnchor = nil
            thread.model = event["model"] as? String
            if let names = event["terminal_slash_commands"] as? [String] {
                ClaudeCommands.terminalOnly = Set(names)
            }
            if let skills = event["skills"] as? [String] {
                ClaudeCommands.skillNames = Set(skills)
            }
            // Every turn starts with init, including ones Claude Code starts itself.
            thread.beginUnsolicitedTurn()

        case "task_started":
            guard event["task_type"] as? String == "local_agent", let id = event["tool_use_id"] as? String else { return }
            if thread.subagents[id] == nil {
                thread.subagents[id] = SubagentRun(
                    description: event["description"] as? String ?? "Subagent",
                    kind: event["subagent_type"] as? String,
                    prompt: event["prompt"] as? String ?? ""
                )
            }
            thread.subagents[id]?.status = .running
            if event["is_backgrounded"] as? Bool == true { thread.backgroundAgents.insert(id) }

        case "task_progress":
            guard let id = event["tool_use_id"] as? String, thread.subagents[id] != nil else { return }
            thread.subagents[id]?.activity = event["description"] as? String

        case "task_notification":
            guard let id = event["tool_use_id"] as? String, thread.subagents[id] != nil else { return }
            let status = event["status"] as? String ?? "completed"
            let finished: ToolCall.Status = status == "completed" ? .done : .failed
            thread.subagents[id]?.status = finished
            thread.subagents[id]?.activity = nil
            thread.subagents[id]?.summary = event["summary"] as? String
            thread.backgroundAgents.remove(id)
            if var call = thread.toolCall(id) {
                call.status = finished
                thread.upsert(id, .tool(call))
            }
            Task { await thread.refreshDiff() }

        default:
            break
        }
    }

    /// Partial messages: text as it's written, for the main agent only.
    @MainActor
    private static func stream(_ event: [String: Any], in thread: AgentThread) {
        switch event["type"] as? String {
        case "message_start":
            thread.streamingMessage = (event["message"] as? [String: Any])?["id"] as? String
        case "content_block_start":
            guard let message = thread.streamingMessage, let index = event["index"] as? Int,
                  (event["content_block"] as? [String: Any])?["type"] as? String == "text"
            else { return }
            thread.startStreamingText(message: message, index: index)
        case "content_block_delta":
            guard let message = thread.streamingMessage, let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return }
            thread.appendStreamedText(text, message: message, index: index)
        default:
            break
        }
    }

    @MainActor
    private static func subagentAssistant(_ message: [String: Any], parent: String, in thread: AgentThread) {
        guard thread.subagents[parent] != nil else { return }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                thread.subagents[parent]?.items.append(TranscriptItem(id: UUID().uuidString, kind: .assistant(text)))
            case "tool_use":
                guard let id = block["id"] as? String else { continue }
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                thread.subagents[parent]?.upsert(id, .tool(ToolCall(name: name, detail: summary(name, input, cwd: thread.worktree))))
            default:
                break
            }
        }
    }

    static func isAgentTool(_ name: String) -> Bool {
        name == "Agent" || name == "Task"
    }

    static func summary(_ name: String, _ input: [String: Any], cwd: URL?) -> String {
        func relative(_ path: String) -> String {
            guard let base = cwd?.path, path.hasPrefix(base + "/") else { return path }
            return String(path.dropFirst(base.count + 1))
        }
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String { return relative(path) }
        if let pattern = input["pattern"] as? String { return pattern }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String { return query }
        if let description = input["description"] as? String { return description }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
