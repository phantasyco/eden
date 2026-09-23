import Foundation

/// Runs helper processes with the user's login-shell PATH, so a GUI launch
/// still finds CLIs installed in ~/.local/bin, Homebrew, and so on.
public enum Shell {
    public struct Output {
        public let stdout: String
        public let stderr: String
        public let status: Int32
    }

    public static let path: String = {
        let fallback = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let login = (try? run("/bin/zsh", ["-lc", "printf %s \"$PATH\""], cwd: nil, environment: nil))?.stdout ?? ""
        var dirs = login.split(separator: ":").map(String.init)
        for dir in fallback where !dirs.contains(dir) { dirs.append(dir) }
        return dirs.joined(separator: ":")
    }()

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        // Don't let a parent Claude Code session (when Eden itself was started
        // from one) leak into the agents we spawn: these name that session,
        // its process, and its messaging socket, not settings of yours.
        for key in [
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
            "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        ] {
            env.removeValue(forKey: key)
        }
        return env
    }

    public static func which(_ name: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String]? = Shell.environment) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    /// Opens a folder in another app, e.g. Finder, Ghostty, or Terminal.
    public static func open(_ url: URL, withApp app: String? = nil) {
        var args: [String] = []
        if let app { args += ["-a", app] }
        args.append(url.path)
        _ = try? run("/usr/bin/open", args, cwd: nil)
    }
}
