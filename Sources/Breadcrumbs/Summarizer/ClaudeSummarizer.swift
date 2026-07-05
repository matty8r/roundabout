import Foundation

enum ClaudeSummarizer {
    struct Result: Decodable {
        let name: String
        let summary: String
    }

    /// Summarizes a working context using recent Claude Code transcript text, if any
    /// exists for this cwd. Returns nil (caller keeps the cheap directory-name label)
    /// when there's no API key or no transcript to summarize from.
    static func summarize(cwd: String, label: String) async -> Result? {
        guard let excerpt = TranscriptReader.excerpt(forCWD: cwd) else { return nil }
        let prompt = """
        Here is a recent excerpt from a coding session in directory "\(label)":

        \(excerpt)

        Give this working context a short human-readable name and a one-sentence summary of what's currently being worked on.
        """
        return await requestSummary(prompt: prompt)
    }

    /// Summarizes a browser tab from its visible page text. Used only when a tab's title
    /// collides with another open tab's (e.g. several generic same-named app tabs), since
    /// that's the case where the title alone can't tell them apart.
    static func summarizeWebPage(title: String, excerpt: String) async -> Result? {
        let prompt = """
        Here is the title and visible text content of a browser tab titled "\(title)":

        \(excerpt)

        This tab's title is shared by other open tabs, so give it a short, distinct name and a
        one-sentence summary of what's specifically happening on this page — something that would
        help someone tell it apart from the other same-titled tabs.
        """
        return await requestSummary(prompt: prompt)
    }

    private static func requestSummary(prompt: String) async -> Result? {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
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
                    fputs("Claude API error (\(( response as? HTTPURLResponse)?.statusCode ?? -1)): \(str)\n", stderr)
                }
                return nil
            }
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = top["content"] as? [[String: Any]],
                  let firstText = content.first(where: { ($0["type"] as? String) == "text" }),
                  let text = firstText["text"] as? String,
                  let textData = text.data(using: .utf8)
            else { return nil }

            guard let decoded = try? JSONDecoder().decode(Result.self, from: textData) else { return nil }
            // An empty name/summary is a "success" by schema but useless in the UI —
            // treat it the same as no result so the cheap label fallback stays visible.
            guard !decoded.name.isEmpty, !decoded.summary.isEmpty else { return nil }
            return decoded
        } catch {
            fputs("Claude API request failed: \(error)\n", stderr)
            return nil
        }
    }
}
