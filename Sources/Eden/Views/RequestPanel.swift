import SwiftUI

/// What the agent is waiting on you for, at the top of the composer: a
/// permission prompt (Allow, Always Allow, Deny) or its questions, with
/// options you can pick by number.
struct RequestPanel: View {
    @Bindable var thread: AgentThread
    let request: AgentRequest

    var body: some View {
        switch request.kind {
        case .approval(let tool, let summary):
            ApprovalView(thread: thread, request: request, tool: tool, summary: summary)
        case .questions(let questions):
            QuestionsView(thread: thread, request: request, questions: questions)
        }
    }
}

private struct ApprovalView: View {
    let thread: AgentThread
    let request: AgentRequest
    let tool: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("\(thread.modelName) wants to \(verb)")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny") { thread.deny(request) }
                    .buttonStyle(.bordered)
                if request.canAlwaysAllow {
                    Button("Always Allow") { thread.approve(request, always: true) }
                        .buttonStyle(.bordered)
                        .help("Allow this and don't ask again for the rest of the session")
                }
                // The one tinted control here: it's what you'll want most often.
                Button("Allow") { thread.approve(request) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var verb: String {
        switch tool {
        case "Bash": "run a command"
        case "Write": "create a file"
        case "Edit", "MultiEdit", "NotebookEdit": "edit a file"
        case "WebFetch": "open a web page"
        case "WebSearch": "search the web"
        case "Delete": "delete a file"
        case "Move": "move a file"
        case "Read": "read a file"
        default: "use \(tool)"
        }
    }
}

/// The agent's AskUserQuestion: each question with its options. One
/// single-choice question answers on the first pick; otherwise Submit sends
/// them all. Number keys pick options of the first unanswered question.
private struct QuestionsView: View {
    let thread: AgentThread
    let request: AgentRequest
    let questions: [AgentQuestion]
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !question.header.isEmpty {
                            Text(question.header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text(question.question).fontWeight(.semibold)
                    }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        OptionRow(number: index + 1, option: option, multiSelect: question.multiSelect,
                                  isSelected: picked[question.key, default: []].contains(option.label)) {
                            pick(option.label, in: question)
                        }
                    }
                    TextField("Other…", text: Binding(
                        get: { other[question.key, default: ""] },
                        set: { other[question.key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(submitIfReady)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button("Skip") { thread.deny(request) }
                    .buttonStyle(.bordered)
                Button("Submit", action: submitIfReady)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReady)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits) { press in
            guard let number = Int(press.characters), number >= 1,
                  let question = questions.first(where: { answer(for: $0) == nil }) ?? questions.first,
                  number <= question.options.count
            else { return .ignored }
            pick(question.options[number - 1].label, in: question)
            return .handled
        }
        // The question takes the keyboard, so 1 to 9 answer it right away.
        .onAppear { focused = true }
    }

    private func pick(_ label: String, in question: AgentQuestion) {
        var set = picked[question.key, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        picked[question.key] = set
        if questions.count == 1, !question.multiSelect { submitIfReady() }
    }

    private func answer(for question: AgentQuestion) -> String? {
        let typed = other[question.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let chosen = question.options.map(\.label).filter { picked[question.key, default: []].contains($0) }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }

    private var isReady: Bool { questions.allSatisfy { answer(for: $0) != nil } }

    private func submitIfReady() {
        guard isReady else { return }
        var answers: [String: String] = [:]
        for question in questions { answers[question.key] = answer(for: question) }
        thread.answer(request, with: answers)
    }
}

private struct OptionRow: View {
    let number: Int
    let option: AgentQuestion.Option
    let multiSelect: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: multiSelect ? "checkmark.square.fill" : "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isSelected ? 0.1 : hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
