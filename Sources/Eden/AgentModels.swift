import Foundation
import Observation

/// The models Cursor, Grok, and OpenCode offer, learned from the CLIs
/// themselves: `cursor-agent models`, Grok's own model cache, and `opencode
/// models --verbose`. Each list is saved, so a launch starts with the last one,
/// and refreshed in the background when Eden opens. Views that list models
/// read `all` and update when a refresh lands.
@Observable
final class AgentModels: @unchecked Sendable {
    static let shared = AgentModels()

    /// Anthropic's and OpenAI's models, then everyone else's.
    private(set) var all: [AIModel] = []
    @ObservationIgnored private var lists: [AgentKind: [AIModel]] = [:]

    private init() {
        lists[.cursor] = Self.cursor(Self.cached(.cursor))
        lists[.grok] = Self.grok()
        lists[.opencode] = Self.opencode(Self.cached(.opencode))
        rebuild()
    }

    private func rebuild() {
        all = ModelCatalog.anthropic + ModelCatalog.openAI
            + [AgentKind.cursor, .grok, .opencode].flatMap { lists[$0] ?? [] }
    }

    /// Asks each installed CLI for its current list. Runs once per launch.
    @MainActor
    func refresh(installed: [AgentKind: Bool]) {
        for (agent, arguments) in [(AgentKind.cursor, ["models"]), (.opencode, ["models", "--verbose"])]
        where installed[agent] == true {
            Task {
                guard let executable = Shell.which(agent.binary) else { return }
                let home = FileManager.default.homeDirectoryForCurrentUser
                guard let out = await Task.detached(operation: { try? Shell.run(executable, arguments, cwd: home) }).value,
                      out.status == 0
                else { return }
                let parsed = agent == .cursor ? Self.cursor(out.stdout) : Self.opencode(out.stdout)
                // A failed or empty listing keeps the last good one.
                guard !parsed.isEmpty else { return }
                Self.save(out.stdout, for: agent)
                lists[agent] = parsed
                rebuild()
            }
        }
        if installed[.grok] == true {
            lists[.grok] = Self.grok()
            rebuild()
        }
    }

    // MARK: Saved lists

    private static var folder: URL { Storage.folder.appendingPathComponent("Models", isDirectory: true) }

    private static func cached(_ agent: AgentKind) -> String {
        (try? String(contentsOf: folder.appendingPathComponent("\(agent.rawValue).txt"), encoding: .utf8)) ?? ""
    }

    private static func save(_ text: String, for agent: AgentKind) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: folder.appendingPathComponent("\(agent.rawValue).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Cursor

    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// `cursor-agent models` prints one line per model and setting, like
    /// "claude-opus-5-5-high-fast - Claude Opus 5.5 1M High Fast". Eden folds
    /// the lines back into one model each, with its reasoning levels and Fast
    /// as options, and remembers which line each combination came from.
    static func cursor(_ text: String) -> [AIModel] {
        struct Family {
            var key: String
            var thinking: Bool
            var names: [String: String] = [:]
            var variants: [String: String] = [:]
            var efforts: Set<String> = []
            var fast = false
        }
        var families: [String: Family] = [:]
        var order: [String] = []

        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { continue }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" ") else { continue }
            let name = clean(parts.dropFirst().joined(separator: " - "))

            var rest = id
            var fast = false, thinking = false
            var effort: String?
            if rest.hasSuffix("-fast") { fast = true; rest.removeLast(5) }
            if rest.hasSuffix("-thinking") { thinking = true; rest.removeLast(9) }
            for (suffix, level) in [("extra-high", "xhigh"), ("xhigh", "xhigh"), ("high", "high"), ("medium", "medium"),
                                    ("low", "low"), ("minimal", "minimal"), ("none", "none"), ("max", "max")]
            where rest.hasSuffix("-" + suffix) {
                effort = level
                rest.removeLast(suffix.count + 1)
                break
            }
            if rest.hasSuffix("-thinking") { thinking = true; rest.removeLast(9) }

            let key = rest + (thinking ? "-thinking" : "")
            if families[key] == nil {
                families[key] = Family(key: key, thinking: thinking)
                order.append(key)
            }
            let variant = "\(effort ?? "")|\(fast)"
            families[key]?.variants[variant] = id
            if let effort { families[key]?.efforts.insert(effort) }
            if fast { families[key]?.fast = true } else { families[key]?.names[effort ?? ""] = name }
        }

        return order.compactMap { key in
            guard var family = families[key] else { return nil }
            // "gpt-5.3-codex" beside "-low" and "-high" is the medium line, unnamed.
            if !family.efforts.isEmpty, !family.efforts.contains("medium"), family.variants["|false"] != nil {
                for fast in [false, true] {
                    family.variants["medium|\(fast)"] = family.variants.removeValue(forKey: "|\(fast)")
                }
                family.names["medium"] = family.names.removeValue(forKey: "")
                family.efforts.insert("medium")
            }
            let efforts = effortOrder.filter { family.efforts.contains($0) }
            // The level whose name carries no level word is Cursor's default:
            // "Claude Opus 5.5 1M" is the medium line.
            let plain = efforts.first { level in
                guard let name = family.names[level] else { return false }
                return !effortWords.contains { name.hasSuffix(" " + $0) || name.hasSuffix(" " + $0 + " Thinking") }
            }
            let defaultEffort = plain ?? (efforts.contains("medium") ? "medium" : efforts.first)
            var name = family.names[defaultEffort ?? ""] ?? family.names.values.first ?? key
            // A note in parentheses ("NO ZDR") becomes the detail.
            var note = ""
            if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
                note = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
            }
            let thinking = name.hasSuffix(" Thinking")
            if thinking { name.removeLast(" Thinking".count) }
            for word in effortWords where name.hasSuffix(" " + word) { name.removeLast(word.count + 1) }
            if thinking { name += " Thinking" }
            name = name.replacingOccurrences(of: " 1M", with: "")
            let long = family.names.values.contains { $0.contains(" 1M") }
            var model = AIModel(
                id: "cursor:" + key,
                name: name,
                detail: key == "auto" ? "Cursor picks the model for each request" : note == "NO ZDR" ? "Without zero data retention" : note,
                agent: .cursor,
                efforts: efforts,
                defaultEffort: efforts.isEmpty ? nil : defaultEffort,
                contextWindow: long ? AIModel.longContextWindow : nil
            )
            model.cliID = key
            model.variants = family.variants
            if family.fast { model.serviceTiers = [.fast] }
            return model
        }
    }

    private static let effortWords = ["Extra High", "High", "Medium", "Low", "Minimal", "None", "Max"]

    /// Cursor pads some names with zero-width spaces and doubled spaces.
    private static func clean(_ name: String) -> String {
        var name = name.replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespaces)
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        for tag in [" (default)", " (current)"] where name.hasSuffix(tag) { name.removeLast(tag.count) }
        return name
    }

    // MARK: Grok

    /// Grok keeps the models your account can use, with their reasoning
    /// levels and context windows, in ~/.grok/models_cache.json.
    static func grok() -> [AIModel] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/models_cache.json")
        let fallback = [grokModel(id: "grok-4.7", name: "Grok 4.7", detail: "", efforts: ["low", "medium", "high", "xhigh"],
                                  defaultEffort: "high", window: 500_000)]
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [String: Any]
        else { return fallback }
        let listed: [AIModel] = models.values.compactMap { entry in
            guard let info = (entry as? [String: Any])?["info"] as? [String: Any] ?? entry as? [String: Any],
                  let id = info["model"] as? String ?? info["id"] as? String,
                  info["hidden"] as? Bool != true
            else { return nil }
            let levels = info["reasoning_efforts"] as? [[String: Any]] ?? []
            let efforts = effortOrder.filter { level in levels.contains { $0["value"] as? String == level } }
            let preferred = levels.first { $0["default"] as? Bool == true }?["value"] as? String
            return grokModel(id: id, name: info["name"] as? String ?? id, detail: info["description"] as? String ?? "",
                             efforts: efforts, defaultEffort: preferred ?? info["reasoning_effort"] as? String,
                             window: info["context_window"] as? Int)
        }
        return listed.isEmpty ? fallback : listed.sorted { $0.name > $1.name }
    }

    private static func grokModel(id: String, name: String, detail: String, efforts: [String], defaultEffort: String?, window: Int?) -> AIModel {
        var model = AIModel(id: "grok:" + id, name: name, detail: detail, agent: .grok, efforts: efforts,
                            defaultEffort: defaultEffort, contextWindow: window)
        model.cliID = id
        return model
    }

    // MARK: OpenCode

    /// `opencode models --verbose` prints each model's id ("google/gemini-3.5-flash")
    /// on a line of its own, then its details as JSON: name, context limit,
    /// and reasoning variants. OpenCode's own default comes first.
    static func opencode(_ text: String) -> [AIModel] {
        var models: [AIModel] = []
        var current: String?
        var block: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("{") {
                block = [line]
            } else if line.hasPrefix("}"), !block.isEmpty {
                block.append(line)
                if let id = current,
                   let json = (try? JSONSerialization.jsonObject(with: Data(block.joined(separator: "\n").utf8))) as? [String: Any] {
                    models.append(opencodeModel(id: id, json))
                }
                block = []
            } else if !block.isEmpty {
                block.append(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                current = line.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !models.isEmpty else { return [] }
        var fallback = AIModel(id: "opencode:default", name: "OpenCode Default",
                               detail: "The model set in OpenCode's own config", agent: .opencode, efforts: [], defaultEffort: nil)
        fallback.cliID = ""
        return [fallback] + models
    }

    private static func opencodeModel(id: String, _ json: [String: Any]) -> AIModel {
        let provider = json["providerID"] as? String ?? String(id.prefix { $0 != "/" })
        let variants = (json["variants"] as? [String: Any]).map { Array($0.keys) } ?? []
        let efforts = effortOrder.filter { variants.contains($0) } + variants.filter { !effortOrder.contains($0) }.sorted()
        var model = AIModel(
            id: "opencode:" + id,
            name: json["name"] as? String ?? id,
            detail: providerNames[provider] ?? provider.capitalized,
            agent: .opencode,
            efforts: efforts,
            defaultEffort: nil,
            isLegacy: (json["status"] as? String).map { $0 != "active" } ?? false,
            contextWindow: (json["limit"] as? [String: Any])?["context"] as? Int
        )
        model.cliID = id
        return model
    }

    private static let providerNames = [
        "opencode": "OpenCode Zen", "google": "Google", "openrouter": "OpenRouter", "nvidia": "NVIDIA",
        "huggingface": "Hugging Face", "zai": "Z.AI", "groq": "Groq", "xai": "xAI", "anthropic": "Anthropic",
        "openai": "OpenAI", "cloudflare-workers-ai": "Cloudflare", "deepseek": "DeepSeek", "mistral": "Mistral",
    ]
}
