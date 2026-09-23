import SwiftUI

/// One session in a window of its own, beside the main window. It shows the
/// same session object, so both windows stay in step.
struct SessionWindow: View {
    @Environment(AppModel.self) private var model
    let id: UUID?

    var body: some View {
        if let thread = model.threads.first(where: { $0.id == id }) {
            NavigationStack {
                ThreadView(thread: thread)
            }
            .navigationTitle(thread.title)
            .background { WindowBackdrop().ignoresSafeArea() }
            .frame(minWidth: 520, minHeight: 420)
        } else {
            ContentUnavailableView("Session Not Found", systemImage: "questionmark.bubble",
                                   description: Text("It may have been deleted."))
                .frame(minWidth: 420, minHeight: 300)
        }
    }
}
