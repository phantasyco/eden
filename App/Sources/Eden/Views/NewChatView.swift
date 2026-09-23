import SwiftUI

/// The new-chat screen, laid out like Help and Shortcuts: a big centered
/// question, a glass field, and suggestions underneath.
struct NewChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelInset) private var panelInset
    @FocusState private var composerFocused: Bool
    @State private var slash = SlashMenuState()
    @AppStorage(Preferences.hiddenModels) private var hiddenModels = ""

    private var choices: [AIModel] {
        ModelVisibility.visible(ModelCatalog.all, hidden: hiddenModels, keeping: model.draftModel)
    }

    private var commands: SlashContext {
        @Bindable var model = model
        return SlashContext(
            app: model, repo: model.draftRepo, thread: nil, choices: choices,
            model: $model.draftModel, effort: $model.draftEffort,
            serviceTier: $model.draftServiceTier, access: $model.draftAccess
        )
    }

    var body: some View {
        @Bindable var model = model
        let suggestions = commands.suggestions(for: model.draftText)
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Where the session runs, above the card: the machine, then the project.
                        HStack(spacing: 2) {
                            Spacer(minLength: 0)
                            MachinePicker()
                            ProjectPicker()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        // One container, so the card and the slash menu's glass
                        // render together instead of one sampling the other.
                        GlassEffectContainer {
                            PromptCard(canSend: canSend, focus: $composerFocused, choices: choices, slash: slash,
                                       suggestions: { commands.suggestions(for: model.draftText) },
                                       submit: submit, accept: accept)
                                // The slash menu drops below the card.
                                .slashMenu(suggestions, state: slash, edge: .bottom, maxHeight: 220, accept: accept)
                        }
                        WorkspaceChips()
                            .padding(.horizontal, 8)
                    }
                    .zIndex(1)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            // Clear of the panel without changing the scroll view's size (see DetailArea).
            .contentMargins(.trailing, panelInset, for: .scrollContent)
        }
        // Fixed minimum width and height keep the split view's size limits constant.
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .navigationTitle("New Session")
        .onAppear { composerFocused = true }
        .onChange(of: model.focusComposerRequest) { composerFocused = true }
        .task(id: "\(model.draftModel.agent.rawValue) \(model.draftRepo?.id ?? "")") {
            if let repo = model.draftRepo { model.loadAgentCommands(for: repo, agent: model.draftModel.agent) }
        }
    }

    /// Same rules as the thread composer: Return picks from an open menu, runs
    /// Eden's commands, and starts a thread with anything else.
    private func submit() {
        if let item = slash.selectedItem(in: commands.suggestions(for: model.draftText)) {
            accept(item, complete: false)
            return
        }
        switch commands.run(model.draftText) {
        case .done: model.draftText = ""
        case .invalid: NSSound.beep()
        case .notCommand: if canSend { model.startDraftThread() }
        }
    }

    private func accept(_ item: SlashItem, complete: Bool) {
        model.draftText = commands.accept(item, complete: complete) { text in
            model.draftText = text
            model.startDraftThread()
        }
    }

    private var canSend: Bool {
        // A project on another machine uses that machine's CLI, not this Mac's.
        (model.installed[model.draftModel.agent] == true || model.draftRepo?.machine.isLocal == false)
            && !model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The prompt as one glass card: the message on top, then "+" and the model
/// chips bottom left and Send bottom right. The chips are neutral and have no
/// glass of their own; Send is the one tinted control. Control rows wrap
/// instead of widening the card.
private struct PromptCard: View {
    @Environment(AppModel.self) private var model
    let canSend: Bool
    var focus: FocusState<Bool>.Binding
    let choices: [AIModel]
    let slash: SlashMenuState
    let suggestions: () -> SlashSuggestions
    let submit: () -> Void
    let accept: (SlashItem, _ complete: Bool) -> Void

    private static let button: CGFloat = 32
    private static let padding: CGFloat = 14
    @State private var dictation = Dictation()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            AttachmentChips(files: $model.draftAttachments)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            TextField("Describe a change, a bug, or a feature", text: $model.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(3...12)
                .focused(focus)
                .onSubmit(submit)
                .slashMenuKeys(text: model.draftText, state: slash, suggestions: suggestions, accept: accept)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 12)

            HStack(alignment: .center, spacing: 4) {
                if dictation.isActive {
                    DictationBar(dictation: dictation, diameter: Self.button)
                        .padding(.trailing, 4)
                } else {
                    ComposerAddMenu(agent: model.draftModel.agent, repo: model.draftRepo,
                                    attach: { model.draftAttachments += $0 }, insert: { model.draftText = $0 + model.draftText },
                                    diameter: Self.button)
                        .padding(.trailing, 4)
                    FlowLayout(spacing: 2) {
                        ModelControls(
                            choices: choices,
                            model: $model.draftModel,
                            effort: $model.draftEffort,
                            serviceTier: $model.draftServiceTier,
                            longContext: $model.draftLongContext,
                            access: $model.draftAccess,
                            extras: $model.draftExtraModels
                        )
                    }
                    Spacer(minLength: 0)
                    DictationButton(dictation: dictation, text: $model.draftText, diameter: Self.button)
                        .padding(.trailing, 4)
                }
                Button(action: submit) {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(CircleButtonStyle(diameter: Self.button, prominent: true))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return). Option-Return adds a new line. Type / for commands.")
            }
        }
        .padding(Self.padding)
        // Concentric: the corner circles' radius plus the padding around them.
        .glassEffect(.regular, in: .rect(cornerRadius: Self.button / 2 + Self.padding))
        .acceptsAttachments($model.draftAttachments)
        // Typing, or sending, ends dictation without touching the message again.
        .onChange(of: model.draftText) { if dictation.isActive, model.draftText != dictation.written { dictation.abandon() } }
        .onDisappear { dictation.abandon() }
    }
}

/// Where in the project the session works, under the card: your checkout or
/// a new worktree, and the branch. Plain chips on the page, not on glass.
private struct WorkspaceChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        FlowLayout(spacing: 2) {
            if model.draftRepo == nil {
                Label("Empty Folder", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .help("With no project, the session works in an empty folder of its own, not your home folder")
            } else if !model.draftIsGit {
                // No git, so no worktrees or branches: the session works in the folder.
                Label("Current Folder", systemImage: "folder")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .help("This folder isn't a git repository, so the session works right in it")
            } else {
                CheckoutPicker(checkout: $model.draftCheckout)
                    // New worktrees are this Mac's for now.
                    .disabled(model.draftRepo?.machine.isLocal == false)
            }
            if model.draftRepo == nil || !model.draftIsGit {
                EmptyView()
            } else if model.draftCheckout == .worktree, !model.draftBranches.isEmpty {
                BranchPicker(branch: $model.draftBranch, branches: model.draftBranches)
            } else if model.draftCheckout == .local, let branch = model.draftBranch {
                // Your checkout's branch is whatever you have checked out; shown, not picked.
                Label(branch, systemImage: "arrow.triangle.branch")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .help("The branch your checkout is on")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

