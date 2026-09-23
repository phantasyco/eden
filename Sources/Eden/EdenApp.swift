import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` binary has no bundle, so it needs a nudge to get a
        // Dock icon and focus. The packaged .app gets both from Launch Services.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    // Agents keep running from the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct EdenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage(Preferences.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(Preferences.theme) private var theme = Theme.eden

    var body: some Scene {
        Window("Eden", id: "main") {
            ContentView()
                .environment(model)
                // The sidebar (up to 320) beside a detail column wide enough for
                // the transcript (300) and the Changes panel (260), plus dividers.
                // The window must never be narrower than the columns' minimums,
                // or the content overflows and clips.
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 860)
        // Only the content's minimum size constrains the window; its ideal size
        // never resizes it. That keeps columns from pushing the window wider.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session", systemImage: "square.and.pencil") { model.newChat() }
                    .keyboardShortcut("n")
                Button("Add Project…", systemImage: "folder.badge.plus") { model.pickRepo() }
                    .keyboardShortcut("o")
                Button("Clone a Project…", systemImage: "arrow.down.circle") { model.showCloneSheet = true }
                Button("Start from Scratch…", systemImage: "sparkles") { model.createRepo() }
                Button("Add Project on Another Machine…", systemImage: "server.rack") { model.showRemoteProjectSheet = true }
            }
            CommandGroup(replacing: .sidebar) {
                Button(model.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("b")
            }
            CommandGroup(after: .sidebar) {
                Button(model.showPanel ? "Hide Panel" : "Show Panel", systemImage: "sidebar.trailing") {
                    if model.showPanel { model.showPanel = false } else { model.openPanel(.home) }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button(model.isShowing(.changes) ? "Hide Changes" : "Show Changes", systemImage: "plus.forwardslash.minus") { model.togglePanel(.changes) }
                    .keyboardShortcut("e")
                    .disabled(model.terminalFolder == nil)
                Button(model.isShowing(.files) ? "Hide Files" : "Show Files", systemImage: "doc") { model.togglePanel(.files) }
                    .keyboardShortcut("p")
                    .disabled(model.terminalFolder == nil)
                Button(model.isShowing(.terminal) ? "Hide Terminal" : "Show Terminal", systemImage: "apple.terminal") { model.togglePanel(.terminal) }
                    .keyboardShortcut("j")
                    .disabled(model.terminalFolder == nil)
                Button(model.isShowing(.browser) ? "Hide Browser" : "Show Browser", systemImage: "globe") { model.togglePanel(.browser) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("New Terminal", systemImage: "plus.rectangle") { model.splitTerminal() }
                    .keyboardShortcut("d")
                    .disabled(model.terminalFolder == nil)
                Button(model.panelExpanded ? "Restore Panel" : "Expand Panel",
                       systemImage: model.panelExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    if model.showPanel { model.panelExpanded.toggle() } else { model.showPanel = true; model.panelExpanded = true }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Eden", systemImage: "hand.wave") { model.showWelcome = true }
            }
            CommandGroup(after: .textEditing) {
                Button("Search Sessions", systemImage: "magnifyingglass") {
                    if model.columnVisibility == .detailOnly { model.toggleSidebar() }
                    model.focusSearchRequest += 1
                }
                .keyboardShortcut("f")
            }
            CommandMenu("Session") {
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!model.canGoForward)
                Divider()
                Button("Previous Session", systemImage: "chevron.up") { model.selectAdjacentThread(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Session", systemImage: "chevron.down") { model.selectAdjacentThread(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Menu("Go to Session", systemImage: "number") {
                    ForEach(1...9, id: \.self) { number in
                        Button("Session \(number)") { model.selectThread(at: number - 1) }
                            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    }
                }
                Divider()
                Button("Stop", systemImage: "stop.circle") { model.selectedThread?.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.selectedThread?.isRunning != true)
            }
        }

        // A session on its own, from "Open in New Window". Restored windows
        // whose session is gone show a short note instead.
        WindowGroup("Session", id: "session", for: UUID.self) { $id in
            SessionWindow(id: id)
                .environment(model)
                .tint(theme.color)
        }
        .defaultSize(width: 900, height: 760)

        Settings {
            SettingsView()
                .environment(model)
                .tint(theme.color)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(model)
        } label: {
            Label("Eden", systemImage: model.runningCount > 0 ? "leaf.fill" : "leaf")
        }
    }
}
