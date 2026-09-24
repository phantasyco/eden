@testable import Eden
import Foundation
import Testing

@Suite("Transcript")
struct TranscriptTests {
    static func tool(_ name: String, _ detail: String = "") -> TranscriptItem.Kind {
        var call = ToolCall(name: name, detail: detail)
        call.status = .done
        return .tool(call)
    }

    static let items: [TranscriptItem] = [
        TranscriptItem(id: "u1", kind: .user("Fix it")),
        TranscriptItem(id: "a1", kind: .assistant("Looking.")),
        TranscriptItem(id: "t1", kind: .thought("**Checking**")),
        TranscriptItem(id: "c1", kind: tool("Bash", "swift build")),
        TranscriptItem(id: "c2", kind: tool("Read", "README.md")),
        TranscriptItem(id: "a2", kind: .assistant("Fixed.")),
        TranscriptItem(id: "u2", kind: .user("Thanks")),
        TranscriptItem(id: "a3", kind: .assistant("Anytime.")),
    ]

    @Test func stepsFoldIntoOneRow() {
        let rows = TranscriptRow.rows(Self.items)
        #expect(rows.map(\.id) == ["u1", "a1", "group-t1", "a2", "u2", "a3"])
    }

    @Test func eachFinishedTurnEndsOnceWithAllItsText() throws {
        let ends = TurnEnd.find(in: TranscriptRow.rows(Self.items), running: false)
        #expect(Set(ends.keys) == ["a2", "a3"])
        #expect(try #require(ends["a2"]).text == "Looking.\n\nFixed.")
    }

    @Test func theRunningTurnHasNoEndYet() {
        let ends = TurnEnd.find(in: TranscriptRow.rows(Self.items), running: true)
        #expect(Set(ends.keys) == ["a2"])
    }

    @Test func checkpointsAreYourMessagesByTheirFirstLine() {
        let items = Self.items + [TranscriptItem(id: "u3", kind: .user("  Next: the header\nwith the details below"))]
        let checkpoints = Checkpoint.all(in: items)
        #expect(checkpoints.map(\.id) == ["u1", "u2", "u3"])
        #expect(checkpoints.last?.text == "Next: the header")
        // Each is a row of its own, so the transcript can scroll to it.
        let rows = Set(TranscriptRow.rows(items).map(\.id))
        #expect(checkpoints.allSatisfy { rows.contains($0.id) })
    }

    @MainActor
    @Test func aBranchCarriesTheConversationAsContext() {
        let context = AgentThread.context(of: Self.items)
        #expect(context.contains("Me: Fix it"))
        #expect(context.contains("You: Fixed."))
        #expect(!context.contains("swift build"))
    }

    @Test func projectsRoundTripThroughWhatsSaved() {
        let remote = Repo(url: URL(fileURLWithPath: "/srv/app"), machine: .ssh("build-box"))
        #expect(remote.stored == "ssh://build-box/srv/app")
        #expect(Repo(stored: remote.stored) == remote)
        #expect(Repo(stored: "/Users/me/code")?.machine == .local)
    }
}
