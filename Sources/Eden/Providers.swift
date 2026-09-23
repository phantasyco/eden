import Foundation

/// What Settings > Providers shows for one CLI: where it's installed, its
/// version, and the account it's signed in to. Eden asks each CLI through its
/// own commands; it never reads their credentials.
struct ProviderStatus {
    var path: String?
    var version: String?
    /// Nil until checked, or when the CLI didn't say.
    var signedIn: Bool?
    var plan: String?

    var isInstalled: Bool { path != nil }
}

enum Providers {
    static func name(of agent: AgentKind) -> String {
        agent.provider
    }

    @MainActor
    static func status(of agent: AgentKind) async -> ProviderStatus {
        guard let path = Shell.which(agent.binary) else { return ProviderStatus() }
        var status = ProviderStatus(path: path)
        let version = await Task.detached { try? Shell.run(path, ["--version"], cwd: nil) }.value
        status.version = version.flatMap { firstVersion(in: $0.stdout + $0.stderr) }

        switch agent {
        case .claude:
            // The same request the slash menu uses; it reports the account without a model call.
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let account = await ClaudeCommands.initialize(in: home)?["account"] as? [String: Any] {
                status.plan = account["subscriptionType"] as? String
                status.signedIn = account["email"] != nil || status.plan != nil
            }
        case .codex:
            // "Logged in using ChatGPT", "Logged in using an API key", or "Not logged in".
            if let login = await Task.detached(operation: { try? Shell.run(path, ["login", "status"], cwd: nil) }).value {
                let text = (login.stdout + login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                status.signedIn = login.status == 0 && text.localizedCaseInsensitiveContains("logged in")
                    && !text.localizedCaseInsensitiveContains("not logged in")
                if let range = text.range(of: "using ", options: .caseInsensitive) {
                    let method = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    status.plan = method.isEmpty ? nil : method.prefix(1).uppercased() + method.dropFirst()
                }
            }
        case .cursor:
            // "Logged in as …" or "Not logged in". The account stays out of Settings.
            if let login = await Task.detached(operation: { try? Shell.run(path, ["status"], cwd: nil) }).value {
                let text = login.stdout + login.stderr
                status.signedIn = text.localizedCaseInsensitiveContains("logged in") && !text.localizedCaseInsensitiveContains("not logged in")
            }
        case .grok:
            // Grok lists your models only when you're signed in.
            if let models = await Task.detached(operation: { try? Shell.run(path, ["models"], cwd: nil) }).value {
                status.signedIn = models.status == 0 && models.stdout.localizedCaseInsensitiveContains("grok")
            }
        case .opencode:
            // OpenCode signs in per model provider; count the ones it has.
            if let auth = await Task.detached(operation: { try? Shell.run(path, ["auth", "list"], cwd: nil) }).value {
                let providers = (auth.stdout + auth.stderr).split(separator: "\n").filter { $0.contains("●") }.count
                status.signedIn = providers > 0
                if providers > 0 { status.plan = providers == 1 ? "1 provider" : "\(providers) providers" }
            }
        }
        return status
    }

    /// "2.1.280 (Claude Code)" and "codex-cli 0.156.0" both give the dotted number.
    private static func firstVersion(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "v(),")) }
            .first { $0.contains(".") && $0.allSatisfy { $0.isNumber || $0 == "." } }
    }
}
