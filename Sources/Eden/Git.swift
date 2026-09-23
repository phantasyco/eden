import Foundation

struct EdenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Git {
    private static var executable: String { Shell.which("git") ?? "/usr/bin/git" }

    @discardableResult
    static func run(_ args: [String], in dir: URL, on machine: Machine = .local) throws -> String {
        let out = try raw(args, in: dir, on: machine)
        guard out.status == 0 else {
            let detail = out.stderr.isEmpty ? out.stdout : out.stderr
            throw EdenError(message: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.stdout
    }

    /// Runs git on the machine, in `dir`, and returns whatever came back.
    static func raw(_ args: [String], in dir: URL, on machine: Machine = .local) throws -> Shell.Output {
        guard !machine.isLocal else { return try Shell.run(executable, args, cwd: dir) }
        let command = machine.command("git", args, in: dir.path)
        return try Shell.run(command.executable, command.arguments, cwd: nil)
    }

    private static let known = NSLock()
    nonisolated(unsafe) private static var repositories: [String: Bool] = [:]

    /// Whether the folder is in a git repository. Projects needn't be: without
    /// git a session works right in the folder, with no worktrees, branches,
    /// or diff. Answers are remembered; `refresh` asks again (on another
    /// machine that's a round trip), as when a session starts, since you can
    /// run `git init` at any time.
    static func isRepository(_ folder: URL, on machine: Machine = .local, refresh: Bool = false) -> Bool {
        let key = machine.name + ":" + folder.path
        if !refresh, let answer = known.withLock({ repositories[key] }) { return answer }
        let answer = (try? run(["rev-parse", "--is-inside-work-tree"], in: folder, on: machine))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        known.withLock { repositories[key] = answer }
        return answer
    }

    /// The remembered answer only, for views that can't wait on git; nil if never asked.
    static func knownRepository(_ folder: URL, on machine: Machine = .local) -> Bool? {
        known.withLock { repositories[machine.name + ":" + folder.path] }
    }

    /// Where the folder sits inside its repository ("apps/web/"), or "" at the top.
    static func prefix(of folder: URL) -> String {
        ((try? run(["rev-parse", "--show-prefix"], in: folder)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func root(of url: URL, on machine: Machine = .local) throws -> URL {
        let path = try run(["rev-parse", "--show-toplevel"], in: url, on: machine)
        return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Local branches, minus the ones Eden created for its own sessions.
    static func branches(of repo: URL, on machine: Machine = .local) -> [String] {
        let out = (try? run(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"], in: repo, on: machine)) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("eden/") }
    }

    /// The owner in the origin remote, like "octocat" for
    /// git@github.com:octocat/hello.git or https://github.com/octocat/hello.
    static func remoteOwner(of repo: URL) -> String? {
        guard let remote = try? run(["config", "--get", "remote.origin.url"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty
        else { return nil }
        let parts = remote.replacingOccurrences(of: ":", with: "/").split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : nil
    }

    /// Start from Scratch: a new repository with a README and a first commit,
    /// since worktrees branch from a commit.
    static func create(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run(["init", "-b", "main"], in: folder)
        try "# \(folder.lastPathComponent)\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run(["add", "-A"], in: folder)
        try run(["commit", "-m", "Initial commit"], in: folder)
    }

    /// Clones into a new folder named after the repository. Git never prompts:
    /// it uses your SSH keys or credential helper, or fails with a message.
    static func clone(_ remote: String, into parent: URL) throws -> URL {
        var name = remote.replacingOccurrences(of: ":", with: "/").split(separator: "/").last.map(String.init) ?? "repository"
        if name.hasSuffix(".git") { name.removeLast(4) }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        var environment = Shell.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // "--" so a remote that starts with "-" can't pass itself off as an option.
        let out = try Shell.run(executable, ["clone", "--", remote, destination.path], cwd: parent, environment: environment)
        guard out.status == 0 else {
            throw EdenError(message: out.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return destination
    }

    /// Copies attached files into `.eden/attachments` in the working folder,
    /// where the agent can read them without asking, and keeps `.eden/` out of
    /// git (and so out of the diff) through the repository's exclude file.
    static func stageAttachments(_ files: [URL], in folder: URL) throws -> [String] {
        let destination = folder.appendingPathComponent(".eden/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if let common = try? run(["rev-parse", "--git-common-dir"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines) {
            let exclude = URL(fileURLWithPath: common, relativeTo: folder).standardizedFileURL.appendingPathComponent("info/exclude")
            let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
            if !existing.split(separator: "\n").contains("/.eden/") {
                try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                try? (existing + separator + "/.eden/\n").write(to: exclude, atomically: true, encoding: .utf8)
            }
        }
        return try files.map { file in
            let name = "\(UUID().uuidString.prefix(6).lowercased())-\(file.lastPathComponent)"
            try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(name))
            return ".eden/attachments/\(name)"
        }
    }

    /// The checked-out branch, or nil on a detached HEAD. `symbolic-ref`
    /// works before the first commit, when `rev-parse HEAD` doesn't.
    static func currentBranch(of repo: URL, on machine: Machine = .local) -> String? {
        let name = (try? run(["symbolic-ref", "--short", "-q", "HEAD"], in: repo, on: machine))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// What a diff compares against: HEAD, or git's empty tree in a
    /// repository with no commits yet, so every file there shows as new.
    private static func diffBase(in dir: URL) -> String {
        if (try? run(["rev-parse", "--verify", "-q", "HEAD"], in: dir)) != nil { return "HEAD" }
        let empty = try? run(["hash-object", "-t", "tree", "/dev/null"], in: dir)
        return empty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    }

    /// Every thread gets its own branch and worktree, so agents never touch the
    /// user's working copy or each other.
    static func createWorktree(repo: URL, name: String, base: String? = nil) throws -> (path: URL, branch: String) {
        let base = base ?? "HEAD"
        _ = try run(["rev-parse", "--verify", base], in: repo)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let parent = support.appendingPathComponent("Eden/worktrees/\(repo.lastPathComponent)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // A thread whose worktree was deleted keeps its branch, so it needs a
        // new name. Prune first so git forgets folders that are already gone.
        _ = try? run(["worktree", "prune"], in: repo)
        var name = name
        var attempt = 2
        func taken(_ candidate: String) -> Bool {
            FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path)
                || (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/eden/\(candidate)"], in: repo)) != nil
        }
        while taken(name) {
            name = name.split(separator: "-").first.map { "\($0)-\(attempt)" } ?? name
            attempt += 1
        }
        let path = parent.appendingPathComponent(name, isDirectory: true)
        let branch = "eden/\(name)"
        try run(["worktree", "add", "-b", branch, path.path, base], in: repo)
        return (path, branch)
    }

    /// Diff against HEAD, plus untracked files, without touching the index
    /// (threads can run in the user's own checkout).
    static func diff(worktree: URL, on machine: Machine = .local) throws -> String {
        if !machine.isLocal { return try remoteDiff(worktree: worktree, on: machine) }
        // quotePath off: non-ASCII paths come through as UTF-8, not octal escapes.
        var out = try run(["-c", "core.quotePath=false", "diff", diffBase(in: worktree), "--no-color", "--no-ext-diff"], in: worktree)
        let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
            .split(separator: "\0").map(String.init)
        for file in untracked.prefix(200) {
            // `git diff --no-index` exits 1 when the files differ, which is always here.
            let result = try Shell.run(executable, ["-c", "core.quotePath=false", "diff", "--no-color", "--no-index", "--", "/dev/null", file], cwd: worktree)
            if result.status <= 1 { out += result.stdout }
        }
        return out
    }

    /// The same diff in one round trip: a connection per untracked file
    /// would make every refresh crawl.
    private static func remoteDiff(worktree: URL, on machine: Machine) throws -> String {
        let script = """
        base=$(git rev-parse --verify -q HEAD >/dev/null && echo HEAD || git hash-object -t tree /dev/null)
        git -c core.quotePath=false diff "$base" --no-color --no-ext-diff
        git ls-files --others --exclude-standard -z | xargs -0 -I{} git -c core.quotePath=false diff --no-color --no-index -- /dev/null {}
        true
        """
        let command = machine.command("sh", ["-c", script], in: worktree.path)
        let out = try Shell.run(command.executable, command.arguments, cwd: nil)
        guard out.status == 0 else { throw EdenError(message: out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out.stdout
    }

    static func commitAll(worktree: URL, message: String, on machine: Machine = .local) throws -> String {
        try run(["add", "-A"], in: worktree, on: machine)
        let out = try run(["commit", "-m", message], in: worktree, on: machine)
        return out.split(separator: "\n").first.map(String.init) ?? "Committed"
    }
}
