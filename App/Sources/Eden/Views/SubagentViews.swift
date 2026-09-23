import SwiftUI

/// A subagent in the transcript: what it was asked to do, how it's going,
/// and a way to open its own transcript in the side panel.
struct SubagentCard: View {
    @Environment(AppModel.self) private var model
    let thread: AgentThread
    let id: String
    @State private var hovered = false

    var body: some View {
        if let run = thread.subagents[id] {
            Button { open() } label: {
                HStack(alignment: .top, spacing: 10) {
                    SubagentStatus(status: run.status)
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.description)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(detail(run))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovered ? 1 : 0.5)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(hovered ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Open this subagent's transcript")
        }
    }

    private func detail(_ run: SubagentRun) -> String {
        let steps = run.items.filter { if case .tool = $0.kind { return true }; return false }.count
        var parts = [run.kind.map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? "Subagent"]
        if steps > 0 { parts.append("\(steps) \(steps == 1 ? "step" : "steps")") }
        switch run.status {
        case .running: if let activity = run.activity { parts.append(activity) }
        case .done: if let summary = run.summary { parts.append(summary) }
        case .failed: parts.append("Didn't finish")
        }
        return parts.joined(separator: " · ")
    }

    private func open() {
        if !thread.openSubagents.contains(id) { thread.openSubagents.append(id) }
        model.openPanel(.subagent(id))
    }
}

struct SubagentStatus: View {
    let status: ToolCall.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

struct PanelTabButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let select: () -> Void
    let close: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: select) {
                Label(title, systemImage: symbol)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered || isSelected ? 1 : 0)
                .help("Close Tab")
            }
        }
        .font(.callout)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(isSelected ? 0.1 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

/// A subagent's own transcript: its task, each step it took, and what it reported.
struct SubagentPanel: View {
    let thread: AgentThread
    let id: String
    @State private var showTask = false

    var body: some View {
        if let run = thread.subagents[id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        SubagentStatus(status: run.status)
                        Text(run.description)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    if !run.prompt.isEmpty {
                        DisclosureGroup("Task", isExpanded: $showTask) {
                            Text(run.prompt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .font(.callout)
                    }
                    ForEach(TranscriptRow.rows(run.items)) { row in
                        switch row {
                        case .item(let item): ItemView(item: item)
                        case .steps(_, let items): StepGroupView(items: items, live: run.status == .running)
                        }
                    }
                    if run.status == .running, let activity = run.activity {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(activity).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if run.items.isEmpty, run.status == .running, run.activity == nil {
                        Text("Starting…").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Subagent Not Found", systemImage: "person.2.slash")
        }
    }
}
