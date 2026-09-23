@testable import Eden
import Foundation
import Testing

@Suite("Agent events")
struct AgentEventTests {
    @Test func acpToolCallsTakeTheirKindInputAndOutput() {
        let folder = URL(fileURLWithPath: "/work/app")
        var call = ToolCall(name: "Tool", detail: "")
        ACPEvents.apply(["toolCallId": "1", "title": "run_terminal_command", "rawInput": ["command": "ls -1"]], to: &call, cwd: folder)
        ACPEvents.apply(["kind": "execute", "status": "completed",
                         "content": [["type": "content", "content": ["type": "text", "text": "README.md\n"]]]], to: &call, cwd: folder)
        #expect(call.name == "Shell")
        #expect(call.detail == "ls -1")
        #expect(call.output == "README.md\n")
        #expect(call.status == .done)
    }

    @Test func acpEditsShowTheirPathRelativeToTheFolder() {
        var call = ToolCall(name: "Tool", detail: "")
        ACPEvents.apply(["kind": "edit", "status": "in_progress", "locations": [["path": "/work/app/Sources/main.swift"]]],
                        to: &call, cwd: URL(fileURLWithPath: "/work/app"))
        #expect(call.name == "Edit")
        #expect(call.detail == "Sources/main.swift")
        #expect(call.status == .running)
    }

    @Test func cursorToolCallsReadTheirWrapper() throws {
        let started = ["shellToolCall": ["args": ["command": "ls"], "description": "List entries"]]
        let running = try #require(CursorEvents.toolCall(started, completed: false, cwd: nil))
        #expect(running.name == "Shell")
        #expect(running.detail == "ls")
        #expect(running.status == .running)

        let finished = ["shellToolCall": ["args": ["command": "ls"], "result": ["success": ["exitCode": 0, "stdout": "README.md\n"]]]]
        let done = try #require(CursorEvents.toolCall(finished, completed: true, cwd: nil))
        #expect(done.output == "README.md\n")
        #expect(done.status == .done)
    }

    @Test func codexCommandsLoseTheirShellWrapper() {
        #expect(CodexEvents.unwrap("/bin/zsh -lc 'swift build'") == "swift build")
        #expect(CodexEvents.unwrap(#"bash -lc "echo \"hi\"""#) == #"echo "hi""#)
        #expect(CodexEvents.unwrap("git status") == "git status")
    }
}
