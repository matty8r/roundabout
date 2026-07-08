import Foundation

/// Writes diagnostics to both stderr (visible when launched from a shell) and a
/// persistent log file (visible regardless of launch method — a login-item launch
/// is started directly by the OS with no shell to redirect stderr from, so without
/// this, anything that goes wrong on an auto-launch-at-login is completely invisible).
enum Log {
    private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Roundabout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("roundabout.log")
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        fputs(line, stderr)
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
}
