import AgentKit
import SwiftUI

/// A toolbar-style button that opens a native popover. Used for the model,
/// reasoning, access, and repository pickers, whose rows need descriptions,
/// badges, and search that macOS menus can't show.
struct PopoverPicker<Content: View>: View {
    let help: String
    let label: String
    let symbol: String
    /// A brand mark shown instead of the symbol, for the model picker.
    var icon: BrandIcon?
    /// Muted details after the label, like the effort after a model's name.
    var suffix: String?
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                Group {
                    if let icon {
                        BrandIconView(icon: icon, size: 14)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                .foregroundStyle(.secondary)
                Text(label)
                if let suffix {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
        }
        // Neutral: these sit on the composer's glass, and only Send is tinted.
        .buttonStyle(ChipButtonStyle(isActive: shown))
        .help(help)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            content { shown = false }
                // A popover inherits the opener's font: callout in a thread's
                // composer, which shrank these rows. Menus always read at body size.
                .font(.body)
                .padding(8)
        }
        .onAppear {
            // Development hook: `-EdenOpenPicker <help text prefix>` opens this
            // popover at launch so it can be screenshotted without clicking.
            if let target = UserDefaults.standard.string(forKey: "EdenOpenPicker"), help.hasPrefix(target) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { shown = true }
            }
        }
    }
}

/// One row in a picker popover: icon, title, optional badge and description,
/// a keyboard hint, and a checkmark when selected.
struct PickerRow: View {
    var symbol: String?
    /// Drawn in place of the symbol, e.g. a repository's badge.
    var icon: AnyView?
    let title: String
    var detail: String?
    var badge: String?
    var shortcut: Int?
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
                if let icon {
                    icon.frame(width: 20)
                        .padding(.top, detail == nil ? 0 : 1)
                } else if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .padding(.top, detail == nil ? 0 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                        if let badge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text("⌘\(shortcut)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovered && isEnabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 }
        .modifier(NumberShortcut(number: shortcut))
    }
}

private struct NumberShortcut: ViewModifier {
    let number: Int?

    func body(content: Content) -> some View {
        if let number, (1...9).contains(number) {
            content.keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
        } else {
            content
        }
    }
}

struct PickerSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Model

/// The model chip: the model's name with its settings as a muted suffix
/// ("Opus 5.5  Medium · 1M · Fast"). The popover lists models by provider,
/// with the chosen model's reasoning, context window, and speed underneath.
/// Picking a model also picks the CLI that runs it.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    let choices: [AIModel]
    @Binding var selection: AIModel
    @Binding var effort: String?
    @Binding var serviceTier: String?
    @Binding var longContext: Bool?
    /// Other models to compare with, for a new session; nil in a session, which has one model.
    var extras: Binding<[String]>?

    var body: some View {
        let others = extras?.wrappedValue.filter { $0 != selection.id }.count ?? 0
        PopoverPicker(help: "Model", label: others > 0 ? "\(selection.name) + \(others)" : selection.name, symbol: "cpu",
                      icon: selection.agent.modelIcon, suffix: suffix) { dismiss in
            ModelPickerContent(choices: choices, installed: model.installed, selection: $selection, effort: $effort,
                               serviceTier: $serviceTier, longContext: $longContext, extras: extras, dismiss: dismiss)
        }
    }

    private var suffix: String? {
        var parts: [String] = []
        if !selection.efforts.isEmpty { parts.append(AgentKind.effortLabel(effort ?? selection.defaultEffort)) }
        if let window = ModelOptions.window(of: selection, longContext: longContext) { parts.append(AIModel.tokens(window)) }
        if let tier = selection.serviceTiers.first(where: { $0.id == serviceTier }) { parts.append(tier.name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ModelOptions {
    /// The context window the model runs with, given the 1M choice.
    static func window(of model: AIModel, longContext: Bool?) -> Int? {
        if model.longContext, longContext ?? model.longContextByDefault { return AIModel.longContextWindow }
        return model.contextWindow
    }
}

private struct ModelPickerContent: View {
    let choices: [AIModel]
    let installed: [AgentKind: Bool]
    @Binding var selection: AIModel
    @Binding var effort: String?
    @Binding var serviceTier: String?
    @Binding var longContext: Bool?
    var extras: Binding<[String]>?
    let dismiss: () -> Void
    @AppStorage(Preferences.favoriteModels) private var favoritesStored = ""
    @State private var comparing = false
    @State private var tab: String?
    @State private var query = ""
    @State private var showLegacy = false
    @FocusState private var searchFocused: Bool

    private static let favoritesTab = "Favorites"

    private var favorites: Set<String> { ModelVisibility.hidden(favoritesStored) }

    private var providers: [String] {
        var seen: [String] = []
        for model in choices where !seen.contains(model.provider) { seen.append(model.provider) }
        return seen
    }

    private var currentTab: String { tab ?? selection.provider }

    /// While searching, every provider; otherwise the tab's models.
    private var listed: [AIModel] {
        if !query.isEmpty {
            return choices.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
        }
        if currentTab == Self.favoritesTab { return choices.filter { favorites.contains($0.id) } }
        return choices.filter { $0.provider == currentTab }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProviderTabs(tabs: [Self.favoritesTab] + providers, selection: currentTab) { tab = $0 }
                .padding(.bottom, 8)
            SearchField(prompt: "Search Models", text: $query, focused: $searchFocused)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    let current = listed.filter { !$0.isLegacy || currentTab == Self.favoritesTab || !query.isEmpty }
                    let legacy = listed.filter { $0.isLegacy && currentTab != Self.favoritesTab && query.isEmpty }
                    ForEach(Array(current.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate, shortcut: index < 9 ? index + 1 : nil)
                    }
                    if !legacy.isEmpty {
                        DisclosureGroup(isExpanded: $showLegacy) {
                            ForEach(legacy) { row($0, shortcut: nil) }
                        } label: {
                            Text("Legacy Models")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(legacy.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    }
                    if listed.isEmpty {
                        Text(currentTab == Self.favoritesTab && query.isEmpty ? "Star a model to keep it here." : "No Models Found")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            if hasOptions || extras != nil {
                Divider().padding(.vertical, 6)
            }
            if let extras {
                // Run the same prompt with several models, each in its own session.
                Toggle(isOn: Binding(get: { comparing }, set: { on in
                    comparing = on
                    if !on { extras.wrappedValue = [] }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Compare Models")
                        Text("Send to each checked model, each in its own worktree.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            if hasOptions {
                ModelOptionRows(model: selection, effort: $effort, serviceTier: $serviceTier, longContext: $longContext)
            }
        }
        .frame(width: 380)
        .onAppear {
            searchFocused = true
            comparing = !(extras?.wrappedValue.isEmpty ?? true)
        }
    }

    private var hasOptions: Bool {
        !selection.efforts.isEmpty || !selection.serviceTiers.isEmpty || selection.longContext
    }

    private func row(_ candidate: AIModel, shortcut: Int?) -> some View {
        ModelRow(
            model: candidate,
            shortcut: shortcut,
            isSelected: candidate == selection || (comparing && extras?.wrappedValue.contains(candidate.id) == true),
            isFavorite: favorites.contains(candidate.id),
            isAvailable: installed[candidate.agent] == true,
            toggleFavorite: {
                var set = favorites
                if set.contains(candidate.id) { set.remove(candidate.id) } else { set.insert(candidate.id) }
                favoritesStored = ModelVisibility.stored(set)
            },
            pick: {
                // Comparing: checking adds or removes a model; the first stays the main one.
                if comparing, let extras, candidate != selection {
                    if let index = extras.wrappedValue.firstIndex(of: candidate.id) {
                        extras.wrappedValue.remove(at: index)
                    } else {
                        extras.wrappedValue.append(candidate.id)
                    }
                    return
                }
                selection = candidate
                dismiss()
            }
        )
    }
}

/// Favorites and each provider, as icons, like the tabs atop Xcode's inspector.
private struct ProviderTabs: View {
    let tabs: [String]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                Button { select(tab) } label: {
                    icon(tab)
                        .frame(width: 34, height: 26)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if tab == selection {
                                Capsule().fill(.tint).frame(width: 18, height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == selection ? .primary : .secondary)
                .opacity(tab == selection ? 1 : 0.7)
                .help(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func icon(_ tab: String) -> some View {
        if let agent = AgentKind.allCases.first(where: { $0.provider == tab }) {
            BrandIconView(icon: agent.modelIcon, size: 16)
        } else {
            Image(systemName: "star").font(.system(size: 14, weight: .medium))
        }
    }
}

/// A model on one line: mark, name, a short description, its ⌘ number, and a star.
private struct ModelRow: View {
    let model: AIModel
    let shortcut: Int?
    let isSelected: Bool
    let isFavorite: Bool
    let isAvailable: Bool
    let toggleFavorite: () -> Void
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: pick) {
                HStack(spacing: 8) {
                    BrandIconView(icon: model.agent.modelIcon, size: 14)
                        .frame(width: 16)
                    Text(model.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .fixedSize()
                    Text(isAvailable ? model.detail : "Not available on this Mac")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let shortcut {
                        Text("⌘\(shortcut)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .modifier(NumberShortcut(number: isAvailable ? shortcut : nil))

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFavorite || hovered ? 1 : 0)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovered && isAvailable ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .opacity(isAvailable ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}

/// Reasoning, context window, and speed for the chosen model, each a row that
/// opens a native menu with the choices checked.
private struct ModelOptionRows: View {
    let model: AIModel
    @Binding var effort: String?
    @Binding var serviceTier: String?
    @Binding var longContext: Bool?

    var body: some View {
        VStack(spacing: 0) {
            if !model.efforts.isEmpty {
                OptionMenuRow(title: "Reasoning", value: AgentKind.effortLabel(effort ?? model.defaultEffort)) {
                    Picker("Reasoning", selection: Binding(get: { effort ?? model.defaultEffort }, set: { effort = $0 })) {
                        ForEach(model.efforts, id: \.self) { level in
                            Text(AgentKind.effortLabel(level) + (level == model.defaultEffort ? " (Default)" : ""))
                                .tag(Optional(level))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            if model.longContext, let standard = model.contextWindow {
                OptionMenuRow(title: "Context Window",
                              value: AIModel.tokens(ModelOptions.window(of: model, longContext: longContext) ?? standard)) {
                    Picker("Context Window", selection: Binding(get: { longContext ?? model.longContextByDefault }, set: { longContext = $0 })) {
                        Text(AIModel.tokens(standard)).tag(false)
                        Text(AIModel.tokens(AIModel.longContextWindow)).tag(true)
                    }
                    .pickerStyle(.inline)
                }
            }
            if model.serviceTiers == [.fast] {
                OptionMenuRow(title: "Fast Mode", value: serviceTier == "fast" ? "On" : "Off") {
                    Picker("Fast Mode", selection: $serviceTier) {
                        Text("Off").tag(String?.none)
                        Text("On").tag(Optional("fast"))
                    }
                    .pickerStyle(.inline)
                }
            } else if !model.serviceTiers.isEmpty {
                OptionMenuRow(title: "Service Tier", value: model.serviceTiers.first { $0.id == serviceTier }?.name ?? "Standard") {
                    Picker("Service Tier", selection: $serviceTier) {
                        Text("Standard").tag(String?.none)
                        ForEach(model.serviceTiers, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
    }
}

private struct OptionMenuRow<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovered = $0 }
    }
}

// MARK: Access

struct AccessPicker: View {
    @Binding var access: AccessMode
    /// The agent the access applies to: each offers only the modes it can honor.
    var agent: AgentKind = .claude

    var body: some View {
        let shown = agent.access(access)
        PopoverPicker(help: "Access", label: shown.label, symbol: shown.symbol) { dismiss in
            VStack(spacing: 2) {
                ForEach(agent.accessModes) { mode in
                    PickerRow(symbol: mode.symbol, title: mode.label, detail: mode.detail(for: agent), isSelected: mode == shown) {
                        access = mode
                        dismiss()
                    }
                }
            }
            .frame(width: 320)
        }
    }
}

// MARK: Machine and project

/// The machine a new session runs on: this Mac, or a host you reach over SSH.
/// Picking one moves to your latest project there, or asks for a folder on it.
struct MachinePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.draftRepo?.machine ?? .local
        PopoverPicker(help: "Machine", label: current.name, symbol: current.symbol) { dismiss in
            MachinePickerContent(current: current, dismiss: dismiss)
        }
    }
}

private struct MachinePickerContent: View {
    @Environment(AppModel.self) private var model
    let current: Machine
    let dismiss: () -> Void
    @State private var hosts = Machine.configuredHosts()

    /// This Mac, the machines with projects, then the rest of your SSH config.
    private var machines: [Machine] {
        var list: [Machine] = [.local]
        for machine in model.repos.map(\.machine) + hosts.map(Machine.ssh) where !list.contains(machine) {
            list.append(machine)
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(machines, id: \.self) { machine in
                    let count = model.repos.filter { $0.machine == machine }.count
                    PickerRow(symbol: machine.symbol, title: machine.name,
                              detail: count == 0 ? "No projects yet" : count == 1 ? "1 project" : "\(count) projects",
                              isSelected: machine == current) {
                        dismiss()
                        model.chooseMachine(machine)
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260)
    }
}

/// The folder a new session works in, among your projects on the chosen
/// machine, with Add Project at the bottom.
struct ProjectPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repo = model.draftRepo
        PopoverPicker(help: "Project", label: repo?.name ?? "No Project", symbol: repo == nil ? "square.dashed" : "folder") { dismiss in
            ProjectPickerContent(machine: repo?.machine ?? .local, dismiss: dismiss)
        }
    }
}

private struct ProjectPickerContent: View {
    @Environment(AppModel.self) private var model
    let machine: Machine
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var projects: [Repo] { model.repos.filter { $0.machine == machine } }

    private var filtered: [Repo] {
        projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchField(prompt: "Search Projects", text: $query, focused: $searchFocused)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { repo in
                        // Where it is only when two projects share a name.
                        let twin = projects.contains { $0 != repo && $0.name == repo.name }
                        PickerRow(symbol: "folder", title: repo.name, detail: twin ? Self.location(of: repo) : nil,
                                  isSelected: repo == model.draftRepo) {
                            model.draftRepo = repo
                            dismiss()
                        }
                    }
                    if filtered.isEmpty {
                        Text("No Projects Found")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 18)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 0) {
                PickerRow(symbol: "plus", title: machine.isLocal ? "Add Project…" : "Add Project on \(machine.name)…",
                          isSelected: false) {
                    dismiss()
                    model.addProject(on: machine)
                }
                // Only on this Mac: the empty folder is made here.
                if machine.isLocal {
                    // The session gets an empty folder of its own, never your home folder.
                    PickerRow(symbol: "xmark", title: "Don't Work in a Project", isSelected: model.draftRepo == nil) {
                        model.draftRepo = nil
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    /// The folder it's in ("in Projects"), to tell same-named projects apart.
    private static func location(of repo: Repo) -> String {
        "in " + repo.url.deletingLastPathComponent().lastPathComponent
    }
}

// MARK: Workspace

/// Where a new thread works: your current checkout or a new worktree.
struct CheckoutPicker: View {
    @Binding var checkout: Checkout

    var body: some View {
        PopoverPicker(help: "Where the agent works", label: checkout.label, symbol: checkout.symbol) { dismiss in
            VStack(spacing: 2) {
                ForEach(Checkout.allCases) { option in
                    PickerRow(symbol: option.symbol, title: option.label, detail: option.detail, isSelected: option == checkout) {
                        checkout = option
                        dismiss()
                    }
                }
            }
            .frame(width: 300)
        }
    }
}

/// The branch a new worktree starts from, with search for repositories that have many.
struct BranchPicker: View {
    @Binding var branch: String?
    let branches: [String]

    var body: some View {
        PopoverPicker(help: "Branch the worktree from", label: branch ?? "HEAD", symbol: "arrow.triangle.branch") { dismiss in
            BranchPickerContent(branch: $branch, branches: branches, dismiss: dismiss)
        }
    }
}

private struct BranchPickerContent: View {
    @Binding var branch: String?
    let branches: [String]
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [String] {
        branches.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if branches.count > 8 {
                SearchField(prompt: "Search Branches", text: $query, focused: $searchFocused)
            }
            ScrollView {
                VStack(spacing: 0) {
                    PickerSectionHeader(title: "Branch From")
                    ForEach(filtered, id: \.self) { name in
                        PickerRow(symbol: "arrow.triangle.branch", title: name, isSelected: name == branch) {
                            branch = name
                            dismiss()
                        }
                    }
                    if filtered.isEmpty {
                        Text("No Branches Found")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 18)
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280)
        .onAppear { searchFocused = true }
    }
}

/// The search field at the top of a picker popover.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Concentric with the popover's rows: a small control, so a rounded rectangle.
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The model chip (with its options inside it) and the access chip.
struct ModelControls: View {
    let choices: [AIModel]
    @Binding var model: AIModel
    @Binding var effort: String?
    @Binding var serviceTier: String?
    @Binding var longContext: Bool?
    @Binding var access: AccessMode
    var extras: Binding<[String]>?

    var body: some View {
        ModelPicker(choices: choices, selection: $model, effort: $effort, serviceTier: $serviceTier, longContext: $longContext, extras: extras)
        AccessPicker(access: $access, agent: model.agent)
    }
}
