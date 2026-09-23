@testable import Eden
import Testing

@Suite("Model lists")
struct ModelListTests {
    /// `cursor-agent models` lists each reasoning level and speed as its own line.
    static let cursorListing = """
    Available models

    auto - Auto (default)
    claude-opus-5-5-low - Claude Opus 5.5 1M Low
    claude-opus-5-5-medium - Claude Opus 5.5 1M
    claude-opus-5-5-high - Claude Opus 5.5 1M High
    claude-opus-5-5-high-fast - Claude Opus 5.5 1M High Fast
    gpt-5.3-codex-low - Codex 5.3 Low
    gpt-5.3-codex - Codex 5.3
    gpt-5.3-codex-high - Codex 5.3 High
    composer-2.5 - Composer 2.5 (current)
    claude-fable-5-thinking-low - Claude Fable 5 Low Thinking (NO ZDR)

    Tip: use --model <id> to switch.
    """

    @Test func cursorFoldsLevelsAndSpeedsIntoOneModel() throws {
        let models = AgentModels.cursor(Self.cursorListing)
        #expect(models.map(\.name) == ["Auto", "Claude Opus 5.5", "Codex 5.3", "Composer 2.5", "Claude Fable 5 Thinking"])

        let opus = try #require(models.first { $0.id == "cursor:claude-opus-5-5" })
        #expect(opus.efforts == ["low", "medium", "high"])
        #expect(opus.defaultEffort == "medium")
        #expect(opus.serviceTiers == [.fast])
        #expect(opus.cliModel(effort: "high", fast: true) == "claude-opus-5-5-high-fast")
        #expect(opus.cliModel(effort: nil, fast: false) == "claude-opus-5-5-medium")
    }

    @Test func cursorsUnnamedLevelIsMedium() throws {
        let codex = try #require(AgentModels.cursor(Self.cursorListing).first { $0.id == "cursor:gpt-5.3-codex" })
        #expect(codex.efforts == ["low", "medium", "high"])
        #expect(codex.cliModel(effort: "medium", fast: false) == "gpt-5.3-codex")
    }

    @Test func cursorsNotesBecomeTheDetail() throws {
        let fable = try #require(AgentModels.cursor(Self.cursorListing).first { $0.name == "Claude Fable 5 Thinking" })
        #expect(fable.detail == "Without zero data retention")
    }

    @Test func opencodeReadsVerboseListings() throws {
        let listing = """
        google/gemini-3.5-flash
        {
          "id": "gemini-3.5-flash",
          "providerID": "google",
          "name": "Gemini 3.5 Flash",
          "status": "active",
          "limit": { "context": 1048576, "output": 65536 },
          "variants": { "low": {}, "high": {}, "minimal": {} }
        }
        """
        let models = AgentModels.opencode(listing)
        #expect(models.first?.id == "opencode:default")
        let flash = try #require(models.first { $0.id == "opencode:google/gemini-3.5-flash" })
        #expect(flash.name == "Gemini 3.5 Flash")
        #expect(flash.detail == "Google")
        #expect(flash.cliID == "google/gemini-3.5-flash")
        #expect(flash.efforts == ["minimal", "low", "high"])
        #expect(flash.contextWindow == 1_048_576)
    }

    @Test func contextSizesReadCleanly() {
        #expect(AIModel.tokens(200_000) == "200K")
        #expect(AIModel.tokens(1_000_000) == "1M")
        #expect(AIModel.tokens(1_048_576) == "1M")
        #expect(AIModel.tokens(1_500_000) == "1.5M")
    }
}
