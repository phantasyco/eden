import Foundation
import Observation

/// Where Eden keeps its own files: a folder named after the app, so the
/// installed Eden and "Eden Dev" keep separate threads the way their bundle IDs
/// keep separate settings. A dev build never touches the conversations you rely on.
enum Storage {
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // A bare `swift run` binary has no bundle; it counts as a dev build.
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Eden Dev"
        return support.appendingPathComponent(name, isDirectory: true)
    }()

    /// Where sessions without a project work: an empty folder each, so an
    /// agent never starts out loose in your home folder.
    static var scratch: URL { folder.appendingPathComponent("Scratch", isDirectory: true) }

    static func newScratchFolder() throws -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let url = scratch.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(4).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// What Eden saves for one thread. The diff isn't saved; the thread reads it
/// from its worktree when it opens.
struct ThreadRecord: Codable {
    var id: UUID
    var agent: AgentKind
    var repo: String
    var title: String
    var access: AccessMode
    var checkout: Checkout
    var baseBranch: String?
    var worktree: String?
    var branch: String?
    var sessionID: String?
    var model: String?
    var modelOverride: String?
    var effort: String?
    var serviceTier: String?
    var updatedAt: Date
    var unread: Bool
    var lastTurnDuration: TimeInterval?
    var costUSD: Double
    var state: RunState
    var turn: Int
    var items: [TranscriptItem]
    // Optional so threads saved before these existed still load.
    var queue: [QueuedMessage]?
    var subagents: [String: SubagentRun]?
    var contextUsed: Int?
    var contextWindow: Int?
    var longContext: Bool?
    var pinned: Bool?
    var archived: Bool?
    var forkPending: Bool?
    var forkAnchor: String?
    var branchContext: String?
}

/// Keeps each thread in its own JSON file, so the sidebar, transcripts, and
/// agent sessions survive a relaunch. Saves wait a second to batch a streaming
/// turn's updates, then encode and write on a serial queue, in order.
@MainActor
final class ThreadStore {
    private let folder = Storage.folder.appendingPathComponent("Threads", isDirectory: true)
    private let queue = DispatchQueue(label: "com.phantasyco.eden.thread-store", qos: .utility)
    private var scheduled: Set<UUID> = []
    private var deleted: Set<UUID> = []

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Saved threads whose repository is still in the sidebar, newest first.
    /// Files for other repositories stay put, in case the folder comes back.
    func load(repos: [Repo]) -> [AgentThread] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let reposByPath = Dictionary(repos.map { ($0.stored, $0) }, uniquingKeysWith: { first, _ in first })
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentThread? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(ThreadRecord.self, from: data),
                      let repo = reposByPath[record.repo] ?? Self.scratchRepo(record.repo)
                else { return nil }
                return AgentThread(record: record, repo: repo)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Saves the thread now, then again whenever anything it saves changes.
    func track(_ thread: AgentThread) {
        save(thread)
    }

    func delete(_ id: UUID) {
        deleted.insert(id)
        let url = file(for: id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Writes every thread before Eden quits, waiting for writes already queued.
    func saveNow(_ threads: [AgentThread]) {
        let writes = threads.filter { !deleted.contains($0.id) }.map { ($0.record, file(for: $0.id)) }
        queue.sync {
            for (record, url) in writes { Self.write(record, to: url) }
        }
    }

    // MARK: Private

    /// A session without a project, whose folder is still there.
    private static func scratchRepo(_ stored: String) -> Repo? {
        guard let repo = Repo(stored: stored), repo.isScratch, FileManager.default.fileExists(atPath: repo.url.path) else { return nil }
        return repo
    }

    private func save(_ thread: AgentThread) {
        guard !deleted.contains(thread.id) else { return }
        // Reading the record inside the tracking closure watches every property
        // it's built from; the next change to any of them schedules another save.
        let record = withObservationTracking {
            thread.record
        } onChange: { [weak self, weak thread] in
            Task { @MainActor in
                guard let self, let thread else { return }
                self.scheduleSave(thread)
            }
        }
        let url = file(for: thread.id)
        queue.async { Self.write(record, to: url) }
    }

    private func scheduleSave(_ thread: AgentThread) {
        guard !scheduled.contains(thread.id) else { return }
        scheduled.insert(thread.id)
        Task { [weak self, weak thread] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let thread else { return }
            self.scheduled.remove(thread.id)
            self.save(thread)
        }
    }

    private func file(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    nonisolated private static func write(_ record: ThreadRecord, to url: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
