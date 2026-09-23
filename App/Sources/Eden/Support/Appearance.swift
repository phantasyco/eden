import AppKit
import SwiftUI

/// Settings keys. Views read them with @AppStorage, so a change in Settings
/// shows up in the main window right away.
enum Preferences {
    static let defaultModel = "defaultModel"
    static let defaultAccess = "defaultAccess"
    static let defaultCheckout = "defaultCheckout"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let colorScheme = "colorScheme"
    static let theme = "theme"
    static let diffColors = "diffColors"
    /// Model IDs hidden from the pickers, comma-separated.
    static let hiddenModels = "hiddenModels"
    static let favoriteModels = "favoriteModels"
    static let hasSeenWelcome = "hasSeenWelcome"
    static let repos = "repos"
    static let terminalHeight = "terminalHeight"
    static let settingsTab = "settingsTab"
    static let sessionSort = "sessionSort"
    static let notifications = "notifications"
    static let terminalTranslucent = "terminalTranslucent"
    static let panelWidth = "panelWidth"
    static let terminalOpacity = "terminalOpacity"
    static let sessionPreviews = "sessionPreviews"
    static let windowTranslucent = "windowTranslucent"
    static let windowTranslucency = "windowTranslucency"
}

/// Light, dark, or whatever the Mac is set to.
enum ColorSchemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applied to NSApp, so every window, menu, and sheet follows it.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The accent Eden tints its controls, icons, and your messages with.
enum Theme: String, CaseIterable, Identifiable {
    case eden, ocean, iris, ember, rose, graphite

    var id: String { rawValue }
    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var color: Color {
        switch self {
        case .eden: Color(red: 0.13, green: 0.66, blue: 0.42)
        case .ocean: Color(red: 0.12, green: 0.49, blue: 0.93)
        case .iris: Color(red: 0.49, green: 0.37, blue: 0.94)
        case .ember: Color(red: 0.95, green: 0.45, blue: 0.16)
        case .rose: Color(red: 0.92, green: 0.28, blue: 0.47)
        case .graphite: Color(red: 0.47, green: 0.49, blue: 0.53)
        }
    }
}

/// How additions and deletions are colored, in diffs and change counts.
enum DiffColors: String, CaseIterable, Identifiable {
    case redGreen, blueOrange

    var id: String { rawValue }
    var label: String { self == .redGreen ? "Red and Green" : "Blue and Orange" }
    var added: Color { self == .redGreen ? .green : .blue }
    var removed: Color { self == .redGreen ? .red : .orange }
}

extension Color {
    /// Eden's default accent, matching the leaf in the app icon.
    static let eden = Theme.eden.color
}

/// Which models the pickers show. Hiding a model only declutters the pickers;
/// a thread already using it keeps it.
enum ModelVisibility {
    static func hidden(_ stored: String) -> Set<String> {
        Set(stored.split(separator: ",").map(String.init))
    }

    static func stored(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }

    /// The models to offer, always including the one already selected.
    static func visible(_ models: [AIModel], hidden stored: String, keeping current: AIModel? = nil) -> [AIModel] {
        let hidden = hidden(stored)
        return models.filter { !hidden.contains($0.id) || $0 == current }
    }
}

/// How the sidebar orders sessions within each section.
enum SessionSort: String, CaseIterable, Identifiable {
    case updated, title

    var id: String { rawValue }
    var label: String { self == .updated ? "Last Updated" : "Title" }
}
