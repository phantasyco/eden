import SwiftUI

/// Clone Repository: a URL, where to put it, and git's own error if it fails.
struct CloneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var parent: URL?
    @State private var cloning = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone a Project").font(.headline)
                Text("Eden clones with git, using your SSH keys or credential helper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField("Repository URL", text: $remote, prompt: Text("git@github.com:owner/repository.git"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            LabeledContent("Clone into") {
                HStack(spacing: 6) {
                    Text((parent ?? model.projectsFolder).path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { choose() }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if cloning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty || cloning)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = parent ?? model.projectsFolder
        if panel.runModal() == .OK { parent = panel.url }
    }

    private func clone() {
        cloning = true
        error = nil
        Task {
            do {
                try await model.cloneRepo(remote.trimmingCharacters(in: .whitespaces), into: parent ?? model.projectsFolder)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            cloning = false
        }
    }
}
