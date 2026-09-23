import Foundation

/// Where a project lives: this Mac, or another machine you reach over SSH.
/// Remote projects run their agents, git, and terminals on that machine
/// through `ssh`, using your SSH config and keys; Eden never asks for a password.
public enum Machine: Hashable, Codable {
    case local
    /// A host alias from `~/.ssh/config`, or `user@host`.
    case ssh(String)

    /// The ssh binary. The engine tests point this at a stand-in.
    public nonisolated(unsafe) static var sshPath = "/usr/bin/ssh"

    public var isLocal: Bool { self == .local }

    public var name: String {
        switch self {
        // Not the computer's name: it's usually the owner's ("Jane's MacBook Pro"),
        // and Eden keeps names out of the UI, which shows up in screenshots.
        case .local: "This Mac"
        case .ssh(let host): host
        }
    }

    public var symbol: String { isLocal ? "laptopcomputer" : "server.rack" }

    /// The hosts named in `~/.ssh/config` (and files it includes from
    /// `~/.ssh/config.d`), minus wildcards and code hosts like github.com.
    public static func configuredHosts() -> [String] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        var files = [ssh.appendingPathComponent("config")]
        if let included = try? FileManager.default.contentsOfDirectory(at: ssh.appendingPathComponent("config.d"), includingPropertiesForKeys: nil) {
            files += included.sorted { $0.path < $1.path }
        }
        var hosts: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let words = line.split(whereSeparator: \.isWhitespace)
                guard words.first?.lowercased() == "host" else { continue }
                for word in words.dropFirst() {
                    let host = String(word)
                    if host.contains("*") || host.contains("?") || host.hasPrefix("!") { continue }
                    if ["github.com", "gitlab.com", "bitbucket.org"].contains(host.lowercased()) { continue }
                    if !hosts.contains(host) { hosts.append(host) }
                }
            }
        }
        return hosts
    }

    /// The command line that runs `executable` with `arguments` in `folder`
    /// on this machine. Remotely that's ssh into a login shell, so the
    /// machine's own PATH finds `claude`, `codex`, and `git`.
    public func command(_ executable: String, _ arguments: [String], in folder: String?, terminal: Bool = false) -> (executable: String, arguments: [String]) {
        guard case .ssh(let host) = self else { return (executable, arguments) }
        let run = ([executable] + arguments).map(Self.quote).joined(separator: " ")
        let inner = (folder.map { "cd \(Self.folder($0)) && " } ?? "") + "exec " + run
        let remote = "exec \"$SHELL\" -lc " + Self.quote(inner)
        return (Self.sshPath, Self.options(terminal: terminal) + [host, remote])
    }

    /// An interactive login shell in `folder`, for the terminal.
    public func shell(in folder: String) -> (executable: String, arguments: [String])? {
        guard case .ssh(let host) = self else { return nil }
        let remote = "cd \(Self.folder(folder)) && exec \"$SHELL\" -l"
        return (Self.sshPath, Self.options(terminal: true) + [host, remote])
    }

    private static func options(terminal: Bool) -> [String] {
        // BatchMode: fail instead of prompting for a password Eden can't show.
        // Keepalives: notice a dropped connection instead of hanging on it.
        // One shared connection per host: a diff refresh after every step of
        // an agent shouldn't pay for a new SSH handshake each time.
        [terminal ? "-t" : "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10",
         "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/eden-ssh-%C", "-o", "ControlPersist=120"]
    }

    /// A folder for `cd`: quoted, except a leading `~/`, which the remote
    /// shell has to see bare to expand to the home folder there.
    public static func folder(_ path: String) -> String {
        path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
    }

    /// Single-quotes a word for a POSIX shell.
    public static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
