import AppKit

enum SafariCollector {
    static func collect() -> [Snapshot] {
        // `tell application "Safari"` launches it if not already running — skip
        // entirely rather than silently opening Safari in the background every poll.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            return []
        }
        let now = Date()
        let safariIsFrontmost = NSWorkspace.shared.frontmostApplication?.localizedName == "Safari"
        return fetchTabs().map { tab in
            let isActiveNow = safariIsFrontmost && tab.isCurrent && tab.isFrontmostWindow
            return Snapshot(
                source: "safari", app: "Safari", title: tab.title, cwd: nil, tty: nil,
                timestamp: now, isFrontmostTab: tab.isCurrent, url: tab.url, isActiveNow: isActiveNow
            )
        }
    }

    private struct TabInfo {
        let url: String
        let title: String
        let isCurrent: Bool
        let isFrontmostWindow: Bool
    }

    /// Enumerates every Safari tab's URL and title, plus whether it's the currently
    /// selected tab in its window and whether that window is the frontmost one. Uses
    /// `(ASCII character 9)` rather than the bare `tab` keyword for the same reason as
    /// the Terminal collector — Safari's own scripting terminology can shadow global
    /// constants inside its `tell` block. Also compares by value (tab index, window id)
    /// rather than AppleScript's `is` object-identity operator, which doesn't reliably
    /// compare two separately-fetched references to the same tab/window as equal — see
    /// the Terminal collector's comment for the same issue. Triggers a one-time
    /// Automation permission prompt on first run.
    private static func fetchTabs() -> [TabInfo] {
        let script = """
        tell application "Safari"
            set outputLines to {}
            set frontWinID to id of (front window)
            repeat with w in windows
                try
                    set winID to id of w
                    set isFront to "0"
                    if winID is frontWinID then set isFront to "1"
                    set currentIndex to index of (current tab of w)
                    repeat with t in tabs of w
                        try
                            set thisIndex to index of t
                            set isCurrent to "0"
                            if thisIndex is currentIndex then set isCurrent to "1"
                            set tabURL to URL of t
                            set tabName to name of t
                            set end of outputLines to (tabURL & (ASCII character 9) & tabName & (ASCII character 9) & isCurrent & (ASCII character 9) & isFront)
                        end try
                    end repeat
                end try
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return outputLines as text
        """
        let (output, errorOutput) = runProcessCapturingStderr("/usr/bin/osascript", ["-e", script])
        if let errorOutput, !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Most commonly a missing/denied Automation permission for Safari — that
            // failure was previously silent (stderr discarded), which is exactly what
            // made a fresh install's "no Safari contexts ever appear, no clue why" bug
            // undiagnosable. Logged every tick rather than once, same as the summarizer's
            // "No summary for X" — cheap, and the alternative (tracking whether we've
            // already warned) isn't worth it for a condition the user should just fix.
            Log.write("Safari tab enumeration failed — check Automation permission for Safari in System Settings: \(errorOutput)\n")
            return []
        }
        guard let output else { return [] }
        return output
            .split(separator: "\n")
            .compactMap { line -> TabInfo? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 4 else { return nil }
                let url = fields[0].trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty else { return nil }
                let title = String(fields[1])
                let isCurrent = fields[2] == "1"
                let isFrontmostWindow = fields[3] == "1"
                return TabInfo(url: url, title: title, isCurrent: isCurrent, isFrontmostWindow: isFrontmostWindow)
            }
    }

    /// Fetches page text for the tab at `url`, which the caller must already know is the
    /// genuinely active/on-screen Safari tab (see `AppDelegate.isSafariTabCurrentlyActive`)
    /// — Accessibility can only ever read what's actually rendered right now, so calling
    /// this for a background tab would just fail (harmlessly) and fall through to the
    /// static-source fallback below, which is strictly worse. Was previously `do JavaScript`
    /// (`document.body.innerText`), which needed the user to enable Safari's Develop menu →
    /// "Allow JavaScript from Apple Events" — a separate, easy-to-miss, per-machine setting
    /// that was the actual root cause of a real user's "summaries don't work on my other
    /// Mac" report. Accessibility needs no extra setup at all (Roundabout already requires
    /// it for the hotkey) and — unlike a `source`-only approach tried and rejected first —
    /// correctly sees JS-rendered content, confirmed empty (`source`) vs. populated
    /// (Accessibility) against a real claude.ai chat tab during development.
    static func fetchActiveTabText(forURL url: String, maxCharacters: Int = 4000) -> String? {
        if let axText = AccessibilityTextReader.fetchVisibleText(bundleIdentifier: "com.apple.Safari", maxCharacters: maxCharacters),
           axText.count > 40 {
            return axText
        }
        return fetchPageTextViaSource(forURL: url, maxCharacters: maxCharacters)
    }

    /// Cheap fallback for the rare page with sparse/poor accessibility support: Safari's
    /// plain `source` property (raw HTML), converted to visible text locally with
    /// `NSAttributedString`'s HTML importer. Gated by Automation alone (already required
    /// for `fetchTabs` above) — but reads the page's *initial* HTML, not the live DOM, so
    /// it silently returns nothing useful for JS-rendered single-page apps (confirmed via a
    /// real claude.ai tab: 15KB of source, 0 characters of extracted text). That gap is why
    /// this is only a fallback now, not the primary path — see `fetchActiveTabText` above.
    private static func fetchPageTextViaSource(forURL url: String, maxCharacters: Int) -> String? {
        let escapedURL = url.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (URL of t) is "\(escapedURL)" then
                            return source of t
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return ""
        """
        let (output, errorOutput) = runProcessCapturingStderr("/usr/bin/osascript", ["-e", script])
        if let errorOutput, !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.write("Safari page-content fetch failed — check Automation permission for Safari in System Settings: \(errorOutput)\n")
            return nil
        }
        guard let output, let data = output.data(using: .utf8), !data.isEmpty else {
            Log.write("Safari page-content fetch returned nothing for \(url) (no tab currently has this exact URL, or the page is genuinely empty).\n")
            return nil
        }
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else {
            Log.write("Safari page-content fetch: couldn't parse HTML for \(url)\n")
            return nil
        }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maxCharacters))
    }

    private static func runProcessCapturingStderr(_ executable: String, _ arguments: [String]) -> (String?, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (nil, nil)
        }
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: outData, encoding: .utf8), String(data: errData, encoding: .utf8))
    }
}
