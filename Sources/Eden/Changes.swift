import Foundation
import Observation

/// Anything the Changes tab can show: a session, or a project with no
/// session selected (your own uncommitted work).
@MainActor
protocol ChangeSource: AnyObject, Observable {
    var diffFiles: [DiffFile] { get }
    var diffStats: DiffStats { get }
    /// The folder the diff comes from; nil while there isn't one yet (a new
    /// worktree before its first message).
    var changesFolder: URL? { get }
    /// False when the folder isn't in a git repository, so there's no diff to show.
    var tracksChanges: Bool { get }
    /// Commits wait while an agent is working in the folder.
    var isRunning: Bool { get }
    func refreshDiff() async
    func commit(message: String) async throws -> String
}

enum DiffLoader {
    /// The diff, parsed, off the main thread: a new repository's first diff
    /// can run to megabytes.
    static func load(_ folder: URL, on machine: Machine) async -> (text: String, files: [DiffFile], stats: DiffStats, isGit: Bool) {
        await Task.detached {
            // Another machine's answer is remembered: asking costs a round trip each refresh.
            guard Git.isRepository(folder, on: machine, refresh: machine.isLocal) else { return ("", [], DiffStats(""), false) }
            let text = (try? Git.diff(worktree: folder, on: machine)) ?? ""
            return (text, DiffFile.parse(text), DiffStats(text), true)
        }.value
    }
}

/// A project's own changes, for the Changes tab when no session is selected.
@MainActor @Observable
final class ProjectChanges: ChangeSource {
    let repo: Repo
    private(set) var diffFiles: [DiffFile] = []
    private(set) var diffStats = DiffStats("")
    private(set) var tracksChanges = true
    var changesFolder: URL? { repo.url }
    var isRunning: Bool { false }

    init(repo: Repo) {
        self.repo = repo
    }

    func refreshDiff() async {
        let loaded = await DiffLoader.load(repo.url, on: repo.machine)
        diffFiles = loaded.files
        diffStats = loaded.stats
        tracksChanges = loaded.isGit
    }

    func commit(message: String) async throws -> String {
        let folder = repo.url, machine = repo.machine
        let summary = try await Task.detached { try Git.commitAll(worktree: folder, message: message, on: machine) }.value
        await refreshDiff()
        return summary
    }
}
