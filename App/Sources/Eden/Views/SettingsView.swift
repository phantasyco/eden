import SwiftUI

enum SettingsTab: String {
    case general, appearance, providers
}

/// Settings in toolbar tabs, like Safari's and Xcode's: General, Appearance,
/// and Providers. It reopens on the last tab you used.
struct SettingsView: View {
    @AppStorage(Preferences.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Appearance", systemImage: "paintpalette", value: SettingsTab.appearance) { AppearanceSettings() }
            Tab("Providers", systemImage: "cpu", value: SettingsTab.providers) { ProviderSettings() }
        }
        .frame(width: 560)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @AppStorage(Preferences.defaultModel) private var defaultModel = ModelCatalog.all[0].id
    @AppStorage(Preferences.defaultAccess) private var defaultAccess = AccessMode.acceptEdits
    @AppStorage(Preferences.defaultCheckout) private var defaultCheckout = Checkout.local
    @AppStorage(Preferences.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(Preferences.notifications) private var notifications = true
    @AppStorage(Preferences.hiddenModels) private var hiddenModels = ""

    var body: some View {
        Form {
            Section("New Sessions") {
                Picker("Model", selection: $defaultModel) {
                    ForEach(AgentKind.allCases) { agent in
                        Section(Providers.name(of: agent)) {
                            let models = ModelCatalog.all.filter { $0.agent == agent && !$0.isLegacy }
                            ForEach(ModelVisibility.visible(models, hidden: hiddenModels, keeping: ModelCatalog.model(defaultModel))) { choice in
                                Text(choice.name).tag(choice.id)
                            }
                        }
                    }
                }
                Picker("Access", selection: $defaultAccess) {
                    ForEach(AccessMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(defaultAccess.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Work in", selection: $defaultCheckout) {
                    ForEach(Checkout.allCases) { checkout in
                        Text(checkout.label).tag(checkout)
                    }
                }
                Text(defaultCheckout == .local
                     ? "The agent edits your checkout directly, on whatever branch it's on."
                     : "Each session gets its own git worktree, so agents never touch your checkout or each other.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify me when a session finishes or needs me", isOn: $notifications)
                    .onChange(of: notifications) { if notifications { Notifier.shared.requestPermission() } }
            } footer: {
                Text("Only for sessions you aren't looking at. Focus and System Settings decide how they appear.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show Eden in the menu bar", isOn: $showMenuBarExtra)
            } footer: {
                Text("Agents keep running from the menu bar after you close the window.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Appearance

/// Laid out like System Settings > Appearance: window previews for the color
/// scheme, then swatches for the accent.
private struct AppearanceSettings: View {
    @AppStorage(Preferences.colorScheme) private var colorScheme = ColorSchemeChoice.system
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    @AppStorage(Preferences.diffColors) private var diffColors = DiffColors.redGreen
    @AppStorage(Preferences.terminalTranslucent) private var terminalTranslucent = true
    @AppStorage(Preferences.terminalOpacity) private var terminalOpacity = 0.8
    @AppStorage(Preferences.glassOpacity) private var glassOpacity = 0.0

    var body: some View {
        Form {
            Section("Appearance") {
                HStack(spacing: 18) {
                    ForEach(ColorSchemeChoice.allCases) { choice in
                        SchemeCard(choice: choice, accent: theme.color, isSelected: choice == colorScheme) {
                            colorScheme = choice
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section("Theme") {
                HStack(spacing: 0) {
                    ForEach(Theme.allCases) { option in
                        ThemeSwatch(theme: option, isSelected: option == theme) { theme = option }
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("Opacity") {
                    HStack(spacing: 8) {
                        Slider(value: $glassOpacity, in: 0...1) {
                            Text("Glass opacity")
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                        .labelsHidden()
                        Text("\(Int((glassOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Glass")
            } footer: {
                Text("How solid the composer, the pills under it, and the slash menu are. Higher keeps text that scrolls underneath from showing through. The toolbar follows macOS.")
                    .foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Toggle("Translucent background", isOn: $terminalTranslucent)
                if terminalTranslucent {
                    LabeledContent("Opacity") {
                        HStack(spacing: 8) {
                            Slider(value: $terminalOpacity, in: 0.3...1) {
                                Text("Opacity")
                            } minimumValueLabel: {
                                Image(systemName: "circle.dotted")
                            } maximumValueLabel: {
                                Image(systemName: "circle.fill")
                            }
                            .labelsHidden()
                            Text("\(Int((terminalOpacity * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            Section {
                Picker("Diff colors", selection: $diffColors) {
                    ForEach(DiffColors.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                LabeledContent("Preview") {
                    HStack(spacing: 8) {
                        Text("+12").foregroundStyle(diffColors.added)
                        Text("−3").foregroundStyle(diffColors.removed)
                    }
                    .font(.body.monospacedDigit().weight(.medium))
                }
            } footer: {
                Text("Eden follows your Mac's accessibility settings for contrast, transparency, and reduced motion.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A miniature Eden window in light or dark, or split between them for Automatic.
private struct SchemeCard: View {
    let choice: ColorSchemeChoice
    let accent: Color
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 7) {
                preview
                    .frame(width: 112, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2.5)
                    )
                Text(choice.label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        switch choice {
        case .light: MiniWindow(dark: false, accent: accent)
        case .dark: MiniWindow(dark: true, accent: accent)
        case .system:
            MiniWindow(dark: false, accent: accent)
                .overlay {
                    MiniWindow(dark: true, accent: accent)
                        .mask(alignment: .trailing) {
                            GeometryReader { geometry in
                                Rectangle().frame(width: geometry.size.width / 2)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                }
        }
    }
}

/// Sidebar, a few lines of transcript, a message bubble, and the composer.
private struct MiniWindow: View {
    let dark: Bool
    let accent: Color

    var body: some View {
        let background = dark ? Color(white: 0.16) : Color(white: 0.99)
        let sidebar = dark ? Color(white: 0.22) : Color(white: 0.92)
        let line = dark ? Color(white: 0.36) : Color(white: 0.82)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index == 1 ? accent.opacity(0.8) : line).frame(width: index == 1 ? 18 : 22, height: 4)
                }
                Spacer()
            }
            .padding(7)
            .frame(width: 34, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(accent).frame(width: 30, height: 7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Capsule().fill(line).frame(width: 50, height: 4)
                Capsule().fill(line).frame(width: 38, height: 4)
                Spacer()
                RoundedRectangle(cornerRadius: 5).fill(line.opacity(0.6)).frame(height: 11)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
        }
    }
}

private struct ThemeSwatch: View {
    let theme: Theme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Circle()
                    .fill(theme.color.gradient)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? theme.color : .clear, lineWidth: 2))
                Text(theme.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(theme.name)
    }
}

// MARK: Providers

/// Each provider's CLI, version, and sign-in, and which of its models the
/// pickers show. This is the one place Eden names the CLIs, since they're
/// what you install and sign in to.
private struct ProviderSettings: View {
    @AppStorage(Preferences.hiddenModels) private var hiddenModels = ""
    @State private var statuses: [AgentKind: ProviderStatus] = [:]
    @State private var checking = false

    var body: some View {
        Form {
            ForEach(AgentKind.allCases) { agent in
                Section {
                    ProviderHeader(agent: agent, status: statuses[agent], checking: checking)
                    if let status = statuses[agent] {
                        // The plan, never the account's email: Settings shows up in screenshots.
                        if let plan = status.plan {
                            LabeledContent(agent == .claude ? "Plan" : "Signed in with", value: plan)
                        }
                        if let path = status.path {
                            LabeledContent("Location") {
                                HStack(spacing: 6) {
                                    Text(path)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).resolvingSymlinksInPath()])
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }
                    }
                    ModelToggles(agent: agent, hiddenModels: $hiddenModels)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Check Again") { Task { await check() } }
                        .disabled(checking)
                }
            } footer: {
                Text("Eden runs each provider's official CLI with the sign-in you already have. It never reads or stores their credentials.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .task { await check() }
    }

    private func check() async {
        checking = true
        for agent in AgentKind.allCases {
            statuses[agent] = await Providers.status(of: agent)
        }
        checking = false
    }
}

private struct ProviderHeader: View {
    let agent: AgentKind
    let status: ProviderStatus?
    let checking: Bool

    var body: some View {
        HStack(spacing: 12) {
            BrandIconView(icon: agent.cliIcon, size: 22)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(Providers.name(of: agent)).font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            badge
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard let status else { return agent.displayName }
        guard status.isInstalled else { return "Install \(agent.displayName) to use \(Providers.name(of: agent)) models" }
        return [agent.displayName, status.version].compactMap { $0 }.joined(separator: " ")
    }

    @ViewBuilder private var badge: some View {
        if status == nil || (checking && status?.signedIn == nil) {
            ProgressView().controlSize(.small)
        } else if status?.isInstalled == false {
            StatusBadge(text: "Not Installed", color: .red)
        } else if status?.signedIn == true {
            StatusBadge(text: "Signed In", color: .green)
        } else if status?.signedIn == false {
            StatusBadge(text: "Not Signed In", color: .orange)
        } else {
            StatusBadge(text: "Installed", color: .secondary)
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout)
        }
        .foregroundStyle(.secondary)
    }
}

/// One switch per model: which ones the pickers offer.
private struct ModelToggles: View {
    let agent: AgentKind
    @Binding var hiddenModels: String
    @State private var expanded = false

    private var models: [AIModel] { ModelCatalog.all.filter { $0.agent == agent } }

    var body: some View {
        let hidden = ModelVisibility.hidden(hiddenModels)
        let shown = models.filter { !hidden.contains($0.id) }.count
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(models) { model in
                Toggle(isOn: binding(for: model)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(model.name)
                            if model.isLegacy {
                                Text("Legacy")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        if !model.detail.isEmpty {
                            Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            LabeledContent("Models", value: "\(shown) of \(models.count) shown")
        }
    }

    private func binding(for model: AIModel) -> Binding<Bool> {
        Binding(
            get: { !ModelVisibility.hidden(hiddenModels).contains(model.id) },
            set: { visible in
                var hidden = ModelVisibility.hidden(hiddenModels)
                if visible { hidden.remove(model.id) } else { hidden.insert(model.id) }
                hiddenModels = ModelVisibility.stored(hidden)
            }
        )
    }
}
