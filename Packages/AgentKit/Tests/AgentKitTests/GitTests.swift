import AgentKit
import Foundation
import Testing

@Suite("Git")
struct GitTests {
    @Test func aPlainFolderIsNotARepositoryUntilGitInit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(!Git.isRepository(folder, refresh: true))
        try Git.run(["init", "-q"], in: folder)
        #expect(Git.isRepository(folder, refresh: true))
        #expect(Git.prefix(of: folder).isEmpty)
    }

    @Test func errorsCarryTheirMessage() {
        #expect(EdenError(message: "nope").localizedDescription == "nope")
    }
}
