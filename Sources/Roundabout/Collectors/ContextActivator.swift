import AppKit

/// Brings the user to a context: focuses the specific terminal tab or browser tab
/// it lives in, or just activates the owning app when we don't have that granularity.
enum ContextActivator {
    static func activate(_ context: Context) {
        if context.app == "Terminal", let tty = context.tty {
            activateTerminalTab(tty: tty)
        } else if context.app == "Safari", let url = context.url {
            activateSafariTab(url: url)
        } else {
            activateApp(named: context.app)
        }
    }

    private static func activateTerminalTab(tty: String) {
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        runOsascript(script)
    }

    private static func activateSafariTab(url: String) {
        let script = """
        tell application "Safari"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (URL of t) is "\(escapeForAppleScriptString(url))" then
                            set current tab of w to t
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        runOsascript(script)
    }

    private static func activateApp(named name: String) {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            running.activate(options: [])
        }
    }

    private static func escapeForAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runOsascript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}
