import Foundation

@main
enum Main {
    static func main() {
        // Agents' input pipes stay open between turns. Writing to one whose
        // process just died raises SIGPIPE, which would end Eden; with it
        // ignored the write fails quietly and the exit handler takes over.
        signal(SIGPIPE, SIG_IGN)

        // Eden --smoke <repo> <model id or name> <prompt> [<prompt> ...]
        // Runs one headless thread end to end, for development without the UI.
        let args = CommandLine.arguments
        if args.count >= 5, args[1] == "--smoke", let model = ModelCatalog.model(args[3]) {
            Task { @MainActor in
                let status = await SmokeTest.run(repo: args[2], model: model, prompts: Array(args[4...]))
                exit(status)
            }
            dispatchMain()
        }
        // macOS reads "-key value" pairs from the command line, so a flag like
        // `--changes` swallows the next argument as its value, and whatever is
        // left over looks like a file to open. A launch that opens files skips
        // Eden's window entirely. Eden has no documents, so it opens none.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        EdenApp.main()
    }
}

@MainActor
enum SmokeTest {
    static func run(repo: String, model: AIModel, prompts: [String]) async -> Int32 {
        let thread = AgentThread(agent: model.agent, repo: Repo(url: URL(fileURLWithPath: repo)))
        thread.modelOverride = model.id
        for prompt in prompts {
            thread.send(prompt)
            while thread.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            print("turn \(thread.turn): \(thread.state)")
        }
        await thread.refreshDiff()
        thread.closeSession()

        for item in thread.items {
            switch item.kind {
            case .user(let text): print("USER      \(text)")
            case .assistant(let text): print("ASSISTANT \(text)")
            case .tool(let call): print("TOOL      \(call.name) [\(call.status)] \(call.detail)")
            case .thought(let text): print("THOUGHT   \(text.prefix(100))")
            case .note(let text): print("NOTE      \(text)")
            case .error(let text): print("ERROR     \(text)")
            }
        }
        print("session=\(thread.sessionID ?? "nil") branch=\(thread.branch ?? "nil") model=\(thread.model ?? "-") cost=$\(String(format: "%.4f", thread.costUSD))")
        print("worktree=\(thread.worktree?.path ?? "nil")")
        print("--- diff ---\n\(thread.diff)")
        if case .failed = thread.state { return 1 }
        return 0
    }
}
