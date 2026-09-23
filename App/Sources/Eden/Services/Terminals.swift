import AgentKit
import AppKit
import SwiftTerm
import SwiftUI

/// The terminal drawer's shells, grouped by the folder they run in: a thread's
/// worktree, or the repository for a new chat. Shells keep running while you
/// switch threads, and end when their pane closes, the shell exits, or Eden quits.
@MainActor @Observable
final class TerminalStore {
    private var panesByFolder: [String: [TerminalPane]] = [:]
    private var focusedByFolder: [String: UUID] = [:]

    func panes(in folder: URL) -> [TerminalPane] {
        panesByFolder[folder.path] ?? []
    }

    func focusedPane(in folder: URL) -> TerminalPane? {
        let panes = panes(in: folder)
        return panes.first { $0.id == focusedByFolder[folder.path] } ?? panes.last
    }

    /// Opens a first shell when the drawer shows a folder that has none.
    func ensurePane(in folder: URL) {
        if panes(in: folder).isEmpty { addPane(in: folder) }
    }

    /// Adds a shell beside the others (Split Terminal, ⌘D) and focuses it.
    func addPane(in folder: URL) {
        let key = folder.path
        let used = Set(panes(in: folder).map(\.number))
        let number = (1...).first { !used.contains($0) }!
        let pane = TerminalPane(number: number, folder: folder)
        pane.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.focusedByFolder[key] = pane.id
        }
        pane.onExit = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.remove(pane, from: key)
        }
        panesByFolder[key, default: []].append(pane)
        focusedByFolder[key] = pane.id
        pane.focusSoon()
    }

    func focus(_ pane: TerminalPane, in folder: URL) {
        focusedByFolder[folder.path] = pane.id
        pane.focusSoon()
    }

    func close(_ pane: TerminalPane, in folder: URL) {
        pane.terminate()
        remove(pane, from: folder.path)
    }

    /// Ends every shell in one folder, as when its thread is removed.
    func closeAll(in folder: URL) {
        for pane in panes(in: folder) { pane.terminate() }
        panesByFolder[folder.path] = nil
        focusedByFolder[folder.path] = nil
    }

    /// Ends every shell, before Eden quits.
    func closeAll() {
        for pane in panesByFolder.values.joined() { pane.terminate() }
        panesByFolder = [:]
    }

    private func remove(_ pane: TerminalPane, from key: String) {
        panesByFolder[key]?.removeAll { $0.id == pane.id }
        if focusedByFolder[key] == pane.id {
            focusedByFolder[key] = panesByFolder[key]?.last?.id
            panesByFolder[key]?.last?.focusSoon()
        }
    }
}

/// One shell: the user's login shell in a pseudo-terminal, drawn by SwiftTerm.
@MainActor @Observable
final class TerminalPane: Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let number: Int
    /// What the shell set as its window title, usually the current directory.
    private(set) var title = ""
    @ObservationIgnored let view = EdenTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 240))
    @ObservationIgnored var onFocus: (() -> Void)?
    @ObservationIgnored var onExit: (() -> Void)?

    init(number: Int, folder: URL) {
        self.number = number
        view.processDelegate = self
        view.onFocus = { [weak self] in self?.onFocus?() }

        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("TERM_PROGRAM=Eden")
        // A project on another machine: `folder` is ssh://host/path, and the
        // shell is a login shell there.
        if folder.scheme == "ssh", let host = folder.host(), let remote = Machine.ssh(host).shell(in: folder.path(percentEncoded: false)) {
            view.startProcess(executable: remote.executable, args: remote.arguments, environment: environment,
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // A leading dash makes it a login shell, so it reads your profile and PATH.
        view.startProcess(
            executable: shell,
            environment: environment,
            execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
            currentDirectory: folder.path
        )
    }

    var name: String { "Terminal \(number)" }

    func focusSoon() {
        // The view may not be in a window yet; give SwiftUI a pass to place it.
        DispatchQueue.main.async { [view] in view.window?.makeFirstResponder(view) }
    }

    /// Closes the shell like closing a Terminal window: a hangup, which an
    /// interactive shell obeys (it ignores SIGTERM) and passes on to its jobs.
    /// A shell still there after two seconds is killed. Either way it's reaped
    /// here, because SwiftTerm stops watching it first and it would linger as
    /// a zombie until Eden quits.
    func terminate() {
        let pid = view.process.shellPid
        view.terminate()
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate (called on the main queue)

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { self.title = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated { onExit?() }
    }
}

/// SwiftTerm's view in Eden's colors: SF Mono on the window's background, with
/// the accent for the caret. It follows light and dark mode as they change.
final class EdenTerminalView: LocalProcessTerminalView {
    var onFocus: (() -> Void)?
    /// The theme's accent, for the caret and selection.
    var accent = NSColor(SwiftUI.Color.eden) {
        didSet { if accent != oldValue { applyColors() } }
    }
    /// How opaque the default background is. Below 1 it shows the blur behind
    /// it; text, the caret, selections, and colored cells stay solid.
    var opacity: CGFloat = 1 {
        didSet { if opacity != oldValue { applyColors() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyColors()
        // SwiftTerm doesn't let subclasses override becomeFirstResponder, so a
        // click that passes straight through marks this pane as the focused one.
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("EdenTerminalView is created in code")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func clicked() {
        onFocus?()
    }

    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        nativeBackgroundColor = Self.background(dark: dark)
        backgroundOpacity = opacity
        nativeForegroundColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.13, alpha: 1)
        caretColor = accent
        selectedTextBackgroundColor = accent.withAlphaComponent(0.35)
        installColors((dark ? Self.darkPalette : Self.lightPalette).map(Self.terminalColor))
    }

    /// The terminal's background, also used for the margins SwiftUI draws around it.
    static func background(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1) : .white
    }

    // The 16 ANSI colors, tuned for each background so prompts and `ls` stay
    // readable. xterm's defaults put cyan and yellow on white, which washes out.
    private static let lightPalette: [UInt32] = [
        0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ]
    private static let darkPalette: [UInt32] = [
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
    ]

    private static func terminalColor(_ hex: UInt32) -> SwiftTerm.Color {
        // SwiftTerm takes 16-bit channels; repeat each byte to fill them.
        func channel(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) * 257 }
        return SwiftTerm.Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}

/// Hosts a pane's terminal view. The view belongs to the pane, not to SwiftUI,
/// so switching threads or hiding the drawer never ends the shell.
struct TerminalPaneView: NSViewRepresentable {
    let pane: TerminalPane
    let accent: SwiftUI.Color
    var opacity: Double = 1

    func makeNSView(context: Context) -> EdenTerminalView {
        pane.view.removeFromSuperview()
        return pane.view
    }

    func updateNSView(_ view: EdenTerminalView, context: Context) {
        view.accent = NSColor(accent)
        view.opacity = opacity
    }

    /// Takes whatever size SwiftUI offers, so the terminal never pushes on the
    /// split view's size limits (see AGENTS.md).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EdenTerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 200)
    }
}

/// A blur of whatever is behind the window, like Terminal.app's translucent
/// background. It stays active when the window isn't key, so the terminal
/// doesn't flash opaque when you click elsewhere.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
