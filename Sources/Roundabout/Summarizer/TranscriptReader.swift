import Foundation

enum TranscriptReader {
    /// Returns a short excerpt of recent human-readable text from the most recent
    /// Claude Code session transcript for this working directory, if one exists.
    static func excerpt(forCWD cwd: String, maxCharacters: Int = 3000) -> String? {
        let sanitized = cwd.replacingOccurrences(of: "/", with: "-")
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(sanitized)")

        // Every failure point here previously returned nil silently — indistinguishable in
        // the log from "processName wasn't 'claude'" (the gate one level up in AppDelegate,
        // which never even calls this), which is exactly why a real report of "I get all the
        // Terminal tabs, just no summaries" on a second Mac had no log evidence to diagnose
        // from. Logged once per distinct cause below, same as the Safari collector fixes.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            Log.write("Terminal transcript lookup failed for \(cwd) — no directory at \(projectsDir.path) (no Claude Code session has run here, or the project directory naming differs from expected).\n")
            return nil
        }

        let transcripts = files.filter { $0.pathExtension == "jsonl" }
        guard let latest = transcripts.max(by: { lhs, rhs in
            modificationDate(lhs) < modificationDate(rhs)
        }) else {
            Log.write("Terminal transcript lookup failed for \(cwd) — \(projectsDir.path) exists but has no .jsonl transcript files.\n")
            return nil
        }

        guard let contents = try? String(contentsOf: latest, encoding: .utf8) else {
            Log.write("Terminal transcript lookup failed for \(cwd) — couldn't read \(latest.path).\n")
            return nil
        }
        let lines = contents.split(separator: "\n").suffix(300)

        var textBlocks: [String] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            for block in content {
                guard let blockType = block["type"] as? String, blockType == "text",
                      let text = block["text"] as? String, !text.isEmpty else { continue }
                textBlocks.append(text)
            }
        }

        guard !textBlocks.isEmpty else {
            Log.write("Terminal transcript lookup for \(cwd) found \(latest.lastPathComponent) but extracted no usable text blocks from the last \(lines.count) lines — transcript format may have changed.\n")
            return nil
        }
        let joined = textBlocks.suffix(12).joined(separator: "\n---\n")
        return String(joined.suffix(maxCharacters))
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
