import Foundation

/// Runs one agent turn: spawns the CLI, writes the prompt to stdin, and hands
/// each JSON line of output to the main actor as it arrives.
final class AgentRunner {
    struct Exit {
        let status: Int32
        let stderr: [String]
    }

    private let process = Process()
    /// Set by terminate(), which can arrive before the process has started.
    private let cancelled = NSLock()
    private var isCancelled = false

    init(executable: String, arguments: [String], cwd: URL) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = Shell.environment
    }

    func run(prompt: String, onEvent: @escaping @MainActor ([String: Any]) -> Void) async throws -> Exit {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        if cancelled.withLock({ isCancelled }) { return Exit(status: 0, stderr: []) }
        try process.run()
        if cancelled.withLock({ isCancelled }) { process.terminate() }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try stdin.fileHandleForWriting.close()

        let errorTail = Task.detached { () -> [String] in
            var tail: [String] = []
            for try await line in stderr.fileHandleForReading.bytes.lines {
                tail.append(line)
                if tail.count > 20 { tail.removeFirst() }
            }
            return tail
        }

        for try await line in stdout.fileHandleForReading.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            await MainActor.run { onEvent(event) }
        }

        var status: Int32 = 0
        for await code in exited { status = code }
        let tail = (try? await errorTail.value) ?? []
        return Exit(status: status, stderr: tail)
    }

    func terminate() {
        cancelled.withLock { isCancelled = true }
        if process.isRunning { process.terminate() }
    }
}
