import Foundation

/// Summarization backend using the Anthropic Messages API — opt-in via the status-bar
/// menu's "Summarization" submenu. FoundationModelsSummarizer (on-device) is the default;
/// this one is for anyone who wants it anyway (higher-quality summaries, no on-device model
/// download) and doesn't mind the cloud round-trip and API key.
struct ClaudeSummarizer: Summarizer {
    private struct APIResult: Decodable {
        let name: String
        let summary: String
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

    /// Keychain first — this is what makes summarization work when launched as a login
    /// item, since that launch path has no shell and never sees `ANTHROPIC_API_KEY` from
    /// the environment. Environment variable as a fallback so the dev-loop workflow
    /// (`source .env` before launching from a shell) keeps working without also requiring
    /// a Keychain entry.
    private func resolveAPIKey() -> String? {
        if let stored = APIKeyStore.load(), !stored.isEmpty {
            return stored
        }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    private func requestSummary(prompt: String) async -> SummarizerResult? {
        guard let apiKey = resolveAPIKey(), !apiKey.isEmpty else {
            return nil
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "2-4 word human-readable label for this working context"],
                "summary": ["type": "string", "description": "One sentence describing what is currently being worked on"]
            ],
            "required": ["name", "summary"],
            "additionalProperties": false
        ]

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 300,
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": schema
                ]
            ],
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let str = String(data: data, encoding: .utf8) {
                    Log.write("Claude API error (\(( response as? HTTPURLResponse)?.statusCode ?? -1)): \(str)\n")
                }
                return nil
            }
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = top["content"] as? [[String: Any]],
                  let firstText = content.first(where: { ($0["type"] as? String) == "text" }),
                  let text = firstText["text"] as? String,
                  let textData = text.data(using: .utf8)
            else { return nil }

            guard let decoded = try? JSONDecoder().decode(APIResult.self, from: textData) else { return nil }
            // An empty name/summary is a "success" by schema but useless in the UI —
            // treat it the same as no result so the cheap label fallback stays visible.
            guard !decoded.name.isEmpty, !decoded.summary.isEmpty else { return nil }
            return SummarizerResult(name: decoded.name, summary: decoded.summary)
        } catch {
            Log.write("Claude API request failed: \(error)\n")
            return nil
        }
    }
}
