import Foundation

/// How a session drives Cursor: one headless run per turn, `cursor-agent -p
/// --output-format stream-json`, resuming the same chat each time. Cursor runs
/// without stopping to ask, so its access comes from flags: without any, it
/// edits files and runs only the commands your Cursor allowlist permits;
/// Auto lets Cursor's reviewer approve the rest; Full Access (`--force`) runs
/// anything. Messages sent while it works wait for the turn to end.
extension AgentThread {
    func cursorArguments(prompt: String, in folder: URL) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--stream-partial-output", "--trust", "--workspace", folder.path]
        if modelOverride != nil {
            args += ["--model", catalogModel.cliModel(effort: effort, fast: serviceTier == "fast")]
        }
        switch effectiveAccess {
        case .auto: args.append("--auto-review")
        case .full: args.append("--force")
        case .supervised, .acceptEdits: break
        }
        if let sessionID { args += ["--resume", sessionID] }
        return args + [prompt]
    }

    func startCursorTurn(_ prompt: String, in folder: URL) throws {
        idleReaper?.cancel()
        let run: AgentProcess
        if repo.machine.isLocal {
            guard let executable = Shell.which(AgentKind.cursor.binary) else {
                throw EdenError(message: "Couldn't find `cursor-agent` on your PATH. Install \(AgentKind.cursor.displayName) first.")
            }
            run = AgentProcess(executable: executable, arguments: cursorArguments(prompt: prompt, in: folder), cwd: folder, configuration: "")
        } else {
            let remote = repo.machine.command(AgentKind.cursor.binary, cursorArguments(prompt: prompt, in: folder), in: folder.path)
            run = AgentProcess(executable: remote.executable, arguments: remote.arguments,
                               cwd: FileManager.default.homeDirectoryForCurrentUser, configuration: "")
        }
        cursorMessage = nil
        cursorResult = nil
        try run.start(
            onEvent: { [weak self, weak run] event in
                guard let self, let run, self.cursor === run else { return }
                CursorEvents.handle(event, in: self)
            },
            onExit: { [weak self, weak run] status, stderr in
                guard let self, let run, self.cursor === run else { return }
                self.cursorExited(status: status, stderr: stderr)
            }
        )
        // The prompt is an argument; nothing more comes on stdin.
        run.closeInput()
        cursor = run
    }

    /// Stop ends the run; the chat keeps everything up to that point.
    func interruptCursor(_ run: AgentProcess) {
        run.terminate()
    }

    private func cursorExited(status: Int32, stderr: [String]) {
        cursor = nil
        endCursorMessage()
        guard isRunning else { return }
        if stopRequested {
            finishTurn(error: nil)
            return
        }
        if let result = cursorResult {
            if result["is_error"] as? Bool == true || result["subtype"] as? String == "error" {
                let message = result["result"] as? String ?? result["error"] as? String ?? "\(modelName) couldn't finish."
                append(.error(message))
                finishTurn(error: message)
            } else {
                finishTurn(error: nil)
            }
            return
        }
        let detail = stderr.suffix(6).joined(separator: "\n")
        let message = detail.isEmpty ? "\(modelName) stopped unexpectedly (exit status \(status))." : detail
        append(.error(message))
        finishTurn(error: message)
    }

    /// Text after a tool call starts a new message, and a new thought.
    func endCursorMessage() {
        cursorThought = nil
        flushStream()
        if let id = cursorMessage, let item = item(id), case .assistant(let text) = item.kind,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeItem(id)
        }
        cursorMessage = nil
    }
}

/// Cursor's stream-json events. With partial output on, each piece of text
/// comes as an `assistant` event with a timestamp; then the whole message
/// comes again, which replaces what streamed in.
enum CursorEvents {
    @MainActor
    static func handle(_ event: [String: Any], in thread: AgentThread) {
        switch event["type"] as? String {
        case "system":
            if event["subtype"] as? String == "init" {
                if let id = event["session_id"] as? String { thread.sessionID = id }
                if let model = event["model"] as? String { thread.model = model }
            }

        case "thinking":
            if event["subtype"] as? String == "completed" {
                thread.cursorThought = nil
                return
            }
            guard let text = event["text"] as? String, !text.isEmpty else { return }
            let id: String
            if let current = thread.cursorThought {
                id = current
            } else {
                id = UUID().uuidString
                thread.cursorThought = id
                thread.append(.thought(""), id: id)
            }
            thread.appendStreamed(text, to: id)

        case "assistant":
            thread.cursorThought = nil
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            let isDelta = event["timestamp_ms"] != nil && event["model_call_id"] == nil
            if isDelta {
                guard !text.isEmpty else { return }
                let id: String
                if let current = thread.cursorMessage {
                    id = current
                } else {
                    id = UUID().uuidString
                    thread.cursorMessage = id
                    thread.append(.assistant(""), id: id)
                }
                thread.appendStreamed(text, to: id)
            } else {
                thread.flushStream()
                if let id = thread.cursorMessage {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { thread.removeItem(id) } else { thread.upsert(id, .assistant(text)) }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    thread.append(.assistant(text))
                }
                thread.cursorMessage = nil
            }

        case "tool_call":
            guard let id = event["call_id"] as? String, let wrapper = event["tool_call"] as? [String: Any] else { return }
            thread.endCursorMessage()
            let completed = event["subtype"] as? String == "completed"
            guard var call = toolCall(wrapper, completed: completed, cwd: thread.worktree) else { return }
            if let existing = thread.toolCall(id), call.output.isEmpty { call.output = existing.output }
            thread.upsert(id, .tool(call))
            if completed { Task { await thread.refreshDiff() } }

        case "result":
            thread.cursorResult = event

        default:
            break
        }
    }

    /// A Cursor tool call: one key naming the tool ("shellToolCall",
    /// "editToolCall"), holding its arguments and, once done, its result.
    static func toolCall(_ wrapper: [String: Any], completed: Bool, cwd: URL?) -> ToolCall? {
        guard let (key, body) = wrapper.first(where: { $0.key.hasSuffix("ToolCall") && $0.value is [String: Any] }),
              let body = body as? [String: Any]
        else { return nil }
        let tool = String(key.dropLast("ToolCall".count))
        let args = body["args"] as? [String: Any] ?? [:]
        let base = cwd.map { $0.path + "/" } ?? ""
        func relative(_ path: String) -> String { path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path }

        let name = names[tool] ?? (tool.prefix(1).uppercased() + tool.dropFirst())
        let detail = (args["command"] as? String)
            ?? (args["path"] as? String ?? args["filePath"] as? String ?? args["targetFile"] as? String).map(relative)
            ?? args["pattern"] as? String ?? args["globPattern"] as? String ?? args["query"] as? String
            ?? args["url"] as? String ?? args["toolName"] as? String ?? args["name"] as? String
            ?? body["description"] as? String ?? ""
        var call = ToolCall(name: name, detail: detail)
        guard completed else { return call }

        let result = body["result"] as? [String: Any] ?? [:]
        if let success = result["success"] as? [String: Any] {
            let exit = success["exitCode"] as? Int ?? 0
            call.status = exit == 0 ? .done : .failed
            let output = success["interleavedOutput"] as? String
                ?? [success["stdout"] as? String, success["stderr"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            call.output = output.utf8.count > 60_000 ? String(output.suffix(40_000)) : output
        } else if let failure = result["error"] as? [String: Any] ?? result["rejected"] as? [String: Any] {
            call.status = .failed
            call.output = failure["message"] as? String ?? failure["errorMessage"] as? String ?? failure["reason"] as? String ?? ""
        } else {
            call.status = .done
        }
        return call
    }

    private static let names = [
        "shell": "Shell", "read": "Read", "edit": "Edit", "write": "Write", "delete": "Delete", "grep": "Grep",
        "glob": "Glob", "ls": "List", "webSearch": "Web search", "webFetch": "Fetch", "mcp": "MCP", "updateTodos": "Todos",
        "todo": "Todos", "readLints": "Lints", "semSearch": "Search",
    ]
}
