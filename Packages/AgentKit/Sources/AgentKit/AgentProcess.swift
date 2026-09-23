import Foundation

/// An agent CLI speaking JSON lines on stdout: Claude Code's stream-json
/// (ClaudeSession), JSON-RPC for Codex and the ACP agents (RPCProcess), or a
/// single Cursor turn.
/// It stays up between turns, so messages sent while the agent works reach it
/// at its next step, and approvals and questions come back over the same pipe.
public class AgentProcess: @unchecked Sendable {
    /// What the process was started with. A different key needs a new process.
    public let configuration: String

    private let process = Process()
    private let stdin = Pipe()
    private let writes = DispatchQueue(label: "com.phantasyco.eden.agent-stdin")
    private let lock = NSLock()
    private var closed = false

    public init(executable: String, arguments: [String], cwd: URL, configuration: String) {
        self.configuration = configuration
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = Shell.environment
    }

    public var isAlive: Bool { process.isRunning && !lock.withLock { closed } }

    /// Starts the process. Each JSON line of output reaches `onEvent` on the
    /// main queue in order; `onExit` runs once, after the last line.
    ///
    /// Output is read with readability handlers, not `FileHandle.bytes`: the
    /// async byte stream hands data over in large chunks or at end of file,
    /// which is fine for a process that exits after each turn but left a
    /// short reply from this one sitting unread in the buffer.
    public func start(
        onEvent: @escaping @MainActor ([String: Any]) -> Void,
        onExit: @escaping @MainActor (_ status: Int32, _ stderr: [String]) -> Void
    ) throws {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let output = OutputState()
        let finish: @Sendable () -> Void = { [weak self] in
            guard let (status, tail) = output.finishIfDone() else { return }
            self?.lock.withLock { self?.closed = true }
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status, tail) } }
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.markOutputClosed()
                finish()
                return
            }
            for line in output.lines(appending: data) {
                guard let parsed = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                // The main queue runs these in the order they're queued.
                nonisolated(unsafe) let event = parsed
                DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            output.appendError(data)
        }
        process.terminationHandler = { finished in
            output.markExited(finished.terminationStatus)
            finish()
        }
        try process.run()
    }

    // MARK: Writing

    public func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let handle = stdin.fileHandleForWriting
        writes.async { [weak self] in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    /// Closes stdin for a process that takes everything it needs as arguments.
    public func closeInput() {
        let handle = stdin.fileHandleForWriting
        writes.async { try? handle.close() }
    }

    // MARK: Ending

    /// Ends the process: closing its input lets it finish cleanly, then
    /// SIGTERM, then SIGKILL if it still hasn't exited.
    public func terminate() {
        let alreadyClosed = lock.withLock {
            defer { closed = true }
            return closed
        }
        guard !alreadyClosed else { return }
        let process = self.process
        let handle = stdin.fileHandleForWriting
        writes.async {
            try? handle.close()
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// One long-lived Claude Code process for a session, speaking stream-json both
/// ways. Stop interrupts the turn without ending the process. The session
/// starts a new process (resuming the conversation) when the model,
/// reasoning, or access changes, or after the process has been idle a while.
public final class ClaudeSession: AgentProcess, @unchecked Sendable {
    /// A message from you: the first of a turn, or one sent into a running turn.
    public func sendUser(_ text: String) {
        write([
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
            "parent_tool_use_id": NSNull(),
            "session_id": "",
        ])
    }

    /// Stops the current turn. The process stays up for the next one.
    public func interrupt() {
        write(["type": "control_request", "request_id": "eden-interrupt-\(UUID().uuidString)", "request": ["subtype": "interrupt"]])
    }

    /// Answers a control request from Claude Code, like a permission prompt.
    public func respond(to requestID: String, with response: [String: Any]) {
        write(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    /// Declines a control request Eden doesn't handle, so Claude Code isn't left waiting.
    public func decline(_ requestID: String, reason: String) {
        write(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": reason]])
    }
}

/// What the session's output handlers share: partial lines, the stderr tail,
/// and whether both the output and the process have ended.
private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var errorText = ""
    private var outputClosed = false
    private var status: Int32?
    private var reported = false

    /// Complete lines from the buffer after adding `data`; a partial line waits for the rest.
    func lines(appending data: Data) -> [Data] {
        lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }

    func appendError(_ data: Data) {
        lock.withLock {
            errorText += String(decoding: data, as: UTF8.self)
            if errorText.count > 8_000 { errorText = String(errorText.suffix(4_000)) }
        }
    }

    func markOutputClosed() { lock.withLock { outputClosed = true } }
    func markExited(_ code: Int32) { lock.withLock { status = code } }

    /// The exit status and stderr tail, once, when output has ended and the process has exited.
    func finishIfDone() -> (Int32, [String])? {
        lock.withLock {
            guard outputClosed, let status, !reported else { return nil }
            reported = true
            let tail = errorText.split(separator: "\n").suffix(20).map(String.init)
            return (status, tail)
        }
    }
}
