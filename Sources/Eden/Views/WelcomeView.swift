import SwiftUI

/// First-launch sheet, laid out like Apple's "What's New" sheets
/// (Voice Memos, Home, Shortcuts): title, feature rows, Continue.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.leading, -6)
                .padding(.bottom, 14)
            Text("Welcome to Eden")
                .font(.title.bold())
            Text("Coding agents, native to your Mac")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 24) {
                FeatureRow(
                    symbol: "square.split.2x1",
                    title: "Run Agents Side by Side",
                    detail: "Work in your checkout, or give a session its own git worktree so agents never collide with each other or with your work."
                )
                FeatureRow(
                    symbol: "plus.forwardslash.minus",
                    title: "Review Before You Commit",
                    detail: "Each change shows up as a diff you can read, then commit right from Eden."
                )
                FeatureRow(
                    symbol: "cpu",
                    title: "Pick Any Model",
                    detail: "Choose an Anthropic or OpenAI model. Eden runs it through the Claude Code or Codex install already on your Mac, with your existing sign-in."
                )
            }
            .padding(.top, 36)

            Spacer(minLength: 24)

            if missingAgents.count == AgentKind.allCases.count {
                Text("Eden runs \(ListFormatter.localizedString(byJoining: missingAgents.map { $0 }).replacingOccurrences(of: " and ", with: " or ")), and none is on this Mac yet. Install one, then relaunch Eden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("Continue").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 56)
        .padding(.top, 52)
        .padding(.bottom, 32)
        .frame(width: 520, height: 560)
    }

    private var missingAgents: [String] {
        AgentKind.allCases.filter { model.installed[$0] != true }.map(\.displayName)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
