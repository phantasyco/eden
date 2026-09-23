@testable import AgentKit
import Testing

@Suite("Machines")
struct MachineTests {
    @Test func thisMacRunsCommandsAsIs() {
        let command = Machine.local.command("claude", ["-p", "hi"], in: "/tmp")
        #expect(command.executable == "claude")
        #expect(command.arguments == ["-p", "hi"])
    }

    @Test func anotherMachineRunsThemInItsLoginShellOverSSH() {
        let command = Machine.ssh("build-box").command("claude", ["-p", "it's"], in: "~/code/app")
        #expect(command.executable == Machine.sshPath)
        #expect(command.arguments.contains("BatchMode=yes"))
        #expect(command.arguments.dropLast().last == "build-box")
        // `~/` stays bare so the remote shell expands it; every word is quoted,
        // then the whole command again for the login shell.
        let inner = #"cd ~/'code/app' && exec 'claude' '-p' 'it'\''s'"#
        #expect(command.arguments.last == #"exec "$SHELL" -lc "# + Machine.quote(inner))
    }

    @Test func quotingSurvivesSingleQuotes() {
        #expect(Machine.quote("it's") == #"'it'\''s'"#)
    }

    @Test func thisMacIsCalledThisMac() {
        #expect(Machine.local.name == "This Mac")
    }
}
