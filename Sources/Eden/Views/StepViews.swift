import SwiftUI

/// Transcript items, with runs of consecutive steps (tool calls and
/// thoughts) folded into one row.
enum TranscriptRow: Identifiable {
    case item(TranscriptItem)
    case steps(id: String, [TranscriptItem])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .steps(let id, _): id
        }
    }

    static func rows(_ items: [TranscriptItem]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [TranscriptItem] = []
        func flush() {
            if run.count > 1 {
                rows.append(.steps(id: "group-" + run[0].id, run))
            } else {
                rows += run.map(TranscriptRow.item)
            }
            run = []
        }
        for item in items {
            switch item.kind {
            // Subagents get a card of their own rather than a line in a group.
            case .tool(let call) where !ClaudeEvents.isAgentTool(call.name):
                run.append(item)
            case .thought:
                run.append(item)
            default:
                flush()
                rows.append(.item(item))
            }
        }
        flush()
        return rows
    }
}

/// A run of steps as one line, "Thought 2 times · ran 2 commands · called 1
/// tool", that opens into a tree of the steps. Open while it's the step the
/// agent is on, folded once it's done, unless you say otherwise.
struct StepGroupView: View {
    let items: [TranscriptItem]
    /// The agent is still working on this run of steps.
    var live = false
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? live }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { expanded = !isExpanded } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(summary)
                    if failures > 0 {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .help(failures == 1 ? "A step failed" : "\(failures) steps failed")
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        StepRow(item: item, branch: index == items.count - 1 ? .last : .middle,
                                live: live && index == items.count - 1)
                    }
                }
                // The tree hangs from under the chevron.
                .padding(.leading, 5)
            }
        }
    }

    private var failures: Int {
        items.filter { if case .tool(let call) = $0.kind { return call.status == .failed }; return false }.count
    }

    private var summary: String {
        var thoughts = 0, commands = 0, reads = 0, edits = 0, searches = 0, tools = 0
        for item in items {
            switch item.kind {
            case .thought: thoughts += 1
            case .tool(let call):
                switch Step.kind(of: call) {
                case .command: commands += 1
                case .read: reads += 1
                case .edit: edits += 1
                case .search, .web: searches += 1
                default: tools += 1
                }
            default: break
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts: [String] = []
        if thoughts == 1 { parts.append("thought process") }
        if thoughts > 1 { parts.append("thought \(thoughts) times") }
        if commands > 0 { parts.append("ran " + count(commands, "command", "commands")) }
        if reads > 0 { parts.append("read " + count(reads, "file", "files")) }
        if edits > 0 { parts.append("edited " + count(edits, "file", "files")) }
        if searches > 0 { parts.append("searched " + count(searches, "time", "times")) }
        if tools > 0 { parts.append("called " + count(tools, "tool", "tools")) }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// How a step reads in the tree: its icon, verb, and what it touched.
enum Step {
    enum Kind { case command, read, edit, search, web, mcp, plan, agent, other }

    static func kind(of call: ToolCall) -> Kind {
        switch call.name {
        case "Bash", "Shell", "Run": .command
        case "Read", "NotebookRead", "List": .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "Delete", "Move": .edit
        case "Grep", "Glob", "Search", "LS": .search
        case "WebSearch", "Web search", "WebFetch", "Fetch": .web
        case "MCP": .mcp
        case "TodoWrite", "Todos": .plan
        case "Task", "Agent": .agent
        default: call.name.hasPrefix("mcp__") ? .mcp : .other
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .command: "apple.terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .mcp: "square.grid.2x2"
        case .plan: "checklist"
        case .agent: "person.2"
        case .other: "wrench.and.screwdriver"
        }
    }

    /// "Run", "Read", "MCP"; Claude Code's MCP tools ("mcp__docs__search") read "MCP".
    static func verb(of call: ToolCall) -> String {
        switch kind(of: call) {
        case .command: "Run"
        case .mcp: "MCP"
        case .plan: "Plan"
        default: call.name
        }
    }

    /// What the step touched; for Claude Code's MCP tools, "server · tool".
    static func detail(of call: ToolCall) -> String {
        guard call.name.hasPrefix("mcp__") else { return call.detail }
        let parts = call.name.dropFirst(5).components(separatedBy: "__")
        let tool = parts.joined(separator: " · ")
        return call.detail.isEmpty ? tool : "\(tool) \(call.detail)"
    }
}

/// One step: a tree branch, the icon, the verb, and what it touched.
/// Clicking it shows the command and its output, or the thought.
struct StepRow: View {
    enum Branch { case none, middle, last }

    let item: TranscriptItem
    var branch = Branch.none
    var live = false
    @State private var expanded = false

    /// Where the branch meets the row: the middle of its first line.
    private static let elbow: CGFloat = 15

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if branch != .none {
                StepBranch(isLast: branch == .last, elbow: Self.elbow)
                    .stroke(.quaternary, lineWidth: 1)
                    .frame(width: 14)
                    .padding(.trailing, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        icon.frame(width: 18)
                        Text(verb).fontWeight(.medium)
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Self.elbow * 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Nothing to open yet; it reads the same as the others, not dimmed.
                .allowsHitTesting(hasContent)

                if expanded || (live && isThought) {
                    content.padding(.leading, 26)
                }
            }
            .padding(.bottom, branch == .none ? 0 : 4)
        }
    }

    private var call: ToolCall? {
        if case .tool(let call) = item.kind { return call }
        return nil
    }

    private var isThought: Bool {
        if case .thought = item.kind { return true }
        return false
    }

    private var verb: String {
        call.map(Step.verb) ?? "Thought process"
    }

    private var detail: String {
        call.map(Step.detail) ?? ""
    }

    private var hasContent: Bool {
        switch item.kind {
        case .thought(let text): !text.isEmpty
        case .tool(let call): !call.detail.isEmpty || !call.output.isEmpty
        default: false
        }
    }

    @ViewBuilder private var icon: some View {
        if let call {
            switch call.status {
            case .running:
                ProgressView().controlSize(.mini)
            case .failed:
                Image(systemName: Step.symbol(Step.kind(of: call))).foregroundStyle(.red)
            case .done:
                Image(systemName: Step.symbol(Step.kind(of: call))).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .thought(let text):
            ThoughtText(text: text)
        case .tool(let call):
            VStack(alignment: .leading, spacing: 6) {
                if Step.kind(of: call) == .command, !call.detail.isEmpty {
                    Text(call.detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !call.output.isEmpty {
                    ScrollView {
                        Text(String(call.output.prefix(40_000)))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        default:
            EmptyView()
        }
    }
}

/// A thought: the headings of Codex's summaries ("Checking the docs"), or
/// the text itself, quietly, in a box that scrolls when it runs long.
private struct ThoughtText: View {
    let text: String

    var body: some View {
        let headings = Self.headings(in: text)
        if headings.isEmpty {
            ScrollView {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(headings, id: \.self) { heading in
                    Text(heading)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .help(text)
        }
    }

    /// Bold lines that open a paragraph: "**Checking documentation guidance**".
    static func headings(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { return nil }
            return String(line.dropFirst(2).dropLast(2))
        }
    }
}

/// The tree's line for one step: down the left edge (to the elbow for the
/// last step) with a branch across to the step.
private struct StepBranch: Shape {
    let isLast: Bool
    let elbow: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + 0.5, y: isLast ? elbow : rect.maxY))
        path.move(to: CGPoint(x: rect.minX + 0.5, y: elbow))
        path.addLine(to: CGPoint(x: rect.maxX, y: elbow))
        return path
    }
}
