import Foundation

/// An agent speaking JSON-RPC over the JSON-lines pipe: Eden sends requests
/// and gets back notifications as the turn runs, plus requests of the agent's
/// own when it needs an approval or an answer.
class RPCProcess: AgentProcess, @unchecked Sendable {
    /// Who's answering, for errors ("Codex stopped before it answered.").
    var agentName: String { "The agent" }
    /// Fields every message carries. ACP wants `"jsonrpc": "2.0"`; Codex doesn't.
    var envelope: [String: Any] { [:] }

    private let rpc = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Sends a request and waits for its result.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = rpc.withLock {
            nextID += 1
            return nextID
        }
        return try await withCheckedThrowingContinuation { continuation in
            rpc.withLock { pending[id] = continuation }
            write(envelope.merging(["id": id, "method": method, "params": params]) { $1 })
        }
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        write(envelope.merging(["method": method, "params": params]) { $1 })
    }

    /// Answers one of the agent's own requests, like an approval.
    func reply(to id: Any, result: [String: Any]) {
        write(envelope.merging(["id": id, "result": result]) { $1 })
    }

    func replyError(to id: Any, message: String) {
        write(envelope.merging(["id": id, "error": ["code": -32601, "message": message]]) { $1 })
    }

    /// If `message` answers one of Eden's requests, hands it to the caller
    /// waiting on it and returns true.
    func settle(_ message: [String: Any]) -> Bool {
        guard message["method"] == nil, let id = message["id"] as? Int else { return false }
        guard let continuation = rpc.withLock({ pending.removeValue(forKey: id) }) else { return true }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: EdenError(message: error["message"] as? String ?? "\(agentName) reported an error."))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
        return true
    }

    /// Fails every request still waiting, when the process has ended.
    func failPending() {
        let waiting = rpc.withLock {
            defer { pending = [:] }
            return Array(pending.values)
        }
        for continuation in waiting {
            continuation.resume(throwing: EdenError(message: "\(agentName) stopped before it answered."))
        }
    }
}

/// Codex's app-server for one session. Eden sends `turn/start`, `turn/steer`,
/// and `turn/interrupt`; see CodexEngine.swift.
final class CodexSession: RPCProcess, @unchecked Sendable {
    override var agentName: String { "Codex" }
}

/// An Agent Client Protocol agent for one session: Grok (`grok agent stdio`)
/// or OpenCode (`opencode acp`). See ACPEngine.swift.
final class ACPSession: RPCProcess, @unchecked Sendable {
    let agent: AgentKind

    init(agent: AgentKind, executable: String, arguments: [String], cwd: URL, configuration: String) {
        self.agent = agent
        super.init(executable: executable, arguments: arguments, cwd: cwd, configuration: configuration)
    }

    override var agentName: String { agent.displayName }
    override var envelope: [String: Any] { ["jsonrpc": "2.0"] }
}
