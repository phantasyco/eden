import AgentKit
import Foundation
import Testing

@Suite("Agent processes")
struct AgentProcessTests {
    /// `cat` echoes each JSON line back: a stand-in agent that proves lines
    /// arrive in order, as they're written, before the process ends.
    @MainActor
    @Test func linesArriveInOrderWhileTheProcessRuns() async throws {
        let process = AgentProcess(executable: "/bin/cat", arguments: [], cwd: FileManager.default.temporaryDirectory, configuration: "")
        var received: [Int] = []
        var exited = false
        try process.start(onEvent: { event in
            if let number = event["n"] as? Int { received.append(number) }
        }, onExit: { _, _ in exited = true })
        for number in 1...3 { process.write(["n": number]) }

        let start = Date()
        while received.count < 3, Date().timeIntervalSince(start) < 5 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received == [1, 2, 3])
        #expect(!exited)

        process.terminate()
        while !exited, Date().timeIntervalSince(start) < 10 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(exited)
    }

    @Test func replyingSettlesTheMatchingRequestOnly() {
        let session = CodexSession(executable: "/bin/cat", arguments: [], cwd: FileManager.default.temporaryDirectory, configuration: "")
        // Not one of Eden's requests: a notification, or a request from the agent.
        #expect(!session.settle(["method": "turn/started", "params": [:]]))
        // A reply to an id nobody is waiting on is still consumed as a reply.
        #expect(session.settle(["id": 99, "result": [:]]))
    }
}
