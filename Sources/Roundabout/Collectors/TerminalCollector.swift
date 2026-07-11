import AppKit

enum TerminalCollector {
    struct TabInfo {
        let tty: String
        let isSelectedInWindow: Bool
        let isFrontmostWindow: Bool
    }

    static func collect() -> [Snapshot] {
        let tabs = fetchTabs()
        let now = Date()
        let terminalIsFrontmost = NSWorkspace.shared.frontmostApplication?.localizedName == "Terminal"
        return tabs.compactMap { tab -> Snapshot? in
            guard let resolved = resolveContext(forTTY: tab.tty) else { return nil }
            let isActiveNow = terminalIsFrontmost && tab.isSelectedInWindow && tab.isFrontmostWindow
            return Snapshot(
                source: "terminal", app: "Terminal", title: nil, cwd: resolved.cwd, tty: tab.tty,
                timestamp: now, isFrontmostTab: tab.isSelectedInWindow, processName: resolved.processName,
                isActiveNow: isActiveNow
            )
        }
    }

    /// Runs an AppleScript against Terminal.app to enumerate every tab's tty, plus
    /// whether it's the currently-selected tab in its window and whether that window is
    /// the frontmost one. Uses `(ASCII character 9)` rather than the bare `tab` keyword —
    /// inside `tell application "Terminal"`, Terminal's own scripting terminology shadows
    /// the global tab-character constant with its "tab" (window tab) noun, so `tab` silently
    /// stringifies to the literal text "tab" instead of a delimiter. Also compares by value
    /// (tty, window id) rather than AppleScript's `is` object-identity operator — two
    /// references fetched via different property accessors (`tabs of w` vs `selected tab
    /// of w`) don't reliably compare as identical even when they're the same underlying
    /// tab, so `t is theSelectedTab` silently evaluated false for every tab. Triggers a
    /// one-time Automation permission prompt on first run.
    private static func fetchTabs() -> [TabInfo] {
        let script = """
        tell application "Terminal"
            set outputLines to {}
            set frontWinID to id of (front window)
            repeat with w in windows
                set winID to id of w
                set isFront to "0"
                if winID is frontWinID then set isFront to "1"
                set selectedTTY to tty of (selected tab of w)
                repeat with t in tabs of w
                    try
                        set thisTTY to tty of t
                        set isSel to "0"
                        if thisTTY is selectedTTY then set isSel to "1"
                        set end of outputLines to (thisTTY & (ASCII character 9) & isSel & (ASCII character 9) & isFront)
                    end try
                end repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return outputLines as text
        """
        let (output, errorOutput) = runProcessCapturingStderr("/usr/bin/osascript", ["-e", script])
        if let errorOutput, !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Most commonly a missing/denied Automation permission for Terminal — that
            // failure was previously silent (stderr discarded), which is exactly what
            // made a fresh install's "no Terminal contexts ever appear, no clue why" bug
            // undiagnosable. See SafariCollector's identical comment.
            Log.write("Terminal tab enumeration failed — check Automation permission for Terminal in System Settings: \(errorOutput)\n")
            return []
        }
        guard let output else { return [] }
        return output
            .split(separator: "\n")
            .compactMap { line -> TabInfo? in
                let fields = line.split(separator: "\t")
                guard let ttyField = fields.first else { return nil }
                let tty = ttyField.trimmingCharacters(in: .whitespaces)
                guard !tty.isEmpty else { return nil }
                let isSelected = fields.count > 1 && fields[1] == "1"
                let isFrontmostWindow = fields.count > 2 && fields[2] == "1"
                return TabInfo(tty: tty, isSelectedInWindow: isSelected, isFrontmostWindow: isFrontmostWindow)
            }
    }

    /// Resolves the cwd and foreground process name for a tty. Uses the BSD `ps` STAT
    /// column's `+` flag (true foreground-process-group membership) rather than "last
    /// line in the listing" — a foreground command can itself spawn a `+`-flagged helper
    /// (e.g. Claude Code spawning `caffeinate`), so among `+` processes we take the one
    /// with the lowest pid, since the original foreground command is always the group's
    /// earliest process and helpers get spawned (and thus pid'd) after it.
    private static func resolveContext(forTTY tty: String) -> (cwd: String, processName: String)? {
        let ttyName = tty.replacingOccurrences(of: "/dev/", with: "")
        guard let psOutput = runProcess("/bin/ps", ["-t", ttyName, "-o", "stat=,pid=,comm="]) else { return nil }
        let entries: [(pid: Int, comm: String)] = psOutput
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 3, fields[0].contains("+"), let pid = Int(fields[1]) else { return nil }
                return (pid, String(fields[2]))
            }

        let target: (pid: Int, comm: String)?
        if let foreground = entries.min(by: { $0.pid < $1.pid }) {
            target = foreground
        } else {
            // No foreground-group process found (unusual) — fall back to the last
            // line of a plain listing so we still surface something rather than nothing.
            let lastLine = psOutput
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .last
            let fields = lastLine?.split(separator: " ", omittingEmptySubsequences: true) ?? []
            if fields.count >= 3, let pid = Int(fields[1]) {
                target = (pid, String(fields[2]))
            } else {
                target = nil
            }
        }
        guard let target else { return nil }

        let pid = String(target.pid)
        let processName = (target.comm as NSString).lastPathComponent

        guard let lsofOutput = runProcess("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]) else { return nil }
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("n") {
                return (String(line.dropFirst()), processName)
            }
        }
        return nil
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe() // discard stderr

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Only used for the AppleScript call, which — unlike the ps/lsof calls above — can
    /// fail for a diagnosable, user-fixable reason (missing Automation permission), so
    /// its stderr is worth surfacing rather than discarding like the plain runProcess above.
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
