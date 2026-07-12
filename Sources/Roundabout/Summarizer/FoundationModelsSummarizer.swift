import FoundationModels
import Foundation

/// On-device summarization backend using Apple's FoundationModels framework — the default
/// summarizer, since it's free, private (nothing leaves the device), and needs no API key.
/// There's deliberately no cloud fallback in here when the model is unavailable: producing
/// no summary (same behavior as ClaudeSummarizer with no key configured) leaves the cheap
/// default label visible instead. Falling back to Anthropic is an explicit user choice via
/// the status-bar menu's "Summarization" submenu, not something this does silently on its
/// own — a user who picked on-device specifically for privacy shouldn't have requests
/// quietly leave the device just because Apple Intelligence isn't enabled today.
struct FoundationModelsSummarizer: Summarizer {
    @Generable
    fileprivate struct GeneratedSummary {
        @Guide(description: "2-4 word human-readable label for this working context")
        var name: String
        @Guide(description: "One sentence describing what is currently being worked on")
        var summary: String
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Human-readable reason the model isn't available, for the menu's tooltip — nil when
    /// it IS available. Phrases Apple's enum cases as something a non-technical user can act
    /// on (turn on Apple Intelligence, wait for the model to finish downloading) rather than
    /// surfacing the raw case name.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence isn't turned on (System Settings → Apple Intelligence & Siri)."
            case .modelNotReady:
                return "The on-device model isn't ready yet — it may still be downloading."
            @unknown default:
                return "The on-device model is unavailable."
            }
        }
    }

    func summarize(cwd: String, label: String) async -> SummarizerResult? {
        guard let excerpt = TranscriptReader.excerpt(forCWD: cwd) else { return nil }
        return await requestSummary(prompt: SummarizerPrompts.terminal(label: label, excerpt: excerpt))
    }

    func summarizeWebPage(title: String, excerpt: String) async -> SummarizerResult? {
        await requestSummary(prompt: SummarizerPrompts.webPage(title: title, excerpt: excerpt))
    }

    func summarizeAppContent(appName: String, excerpt: String) async -> SummarizerResult? {
        await requestSummary(prompt: SummarizerPrompts.appContent(appName: appName, excerpt: excerpt))
    }

    private func requestSummary(prompt: String) async -> SummarizerResult? {
        guard Self.isAvailable else { return nil }
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedSummary.self)
            let content = response.content
            // Same rationale as ClaudeSummarizer: an empty name/summary is a "success" by
            // schema but useless in the UI — fall back to the cheap label instead.
            guard !content.name.isEmpty, !content.summary.isEmpty else { return nil }
            return SummarizerResult(name: content.name, summary: content.summary)
        } catch {
            Log.write("FoundationModels request failed: \(error)\n")
            return nil
        }
    }
}
