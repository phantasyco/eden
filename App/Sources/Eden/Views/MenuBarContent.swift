import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = model.threads.filter(\.isRunning)
        if running.isEmpty {
            Text("No Agents Running")
        } else {
            ForEach(running) { thread in
                Button("\(thread.modelName): \(thread.title)") { show(thread) }
            }
        }
        Divider()
        Button("Open Eden") { show(nil) }
        Button("Quit Eden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ thread: AgentThread?) {
        if let thread { model.selection = .thread(thread.id) }
        openWindow(id: "main")
        NSApp.activate()
    }
}
