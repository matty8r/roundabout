import Foundation

enum ContextClusterer {
    private struct Accumulator {
        var cwd: String?
        var label: String
        var lastSeen: Date
        var sources: Set<String> = []
        var app: String = ""
        var tty: String?
        var processName: String?
        var url: String?
        var representativePriority: Int = -1       // higher wins; selected-tab beats plain recency
        var representativeTimestamp: Date = .distantPast
    }

    /// One context per (cwd, foreground process) for terminal snapshots, one per url
    /// for browser tabs — so an idle shell and an active Claude session in the same
    /// directory (or two different browser tabs) don't get merged into one entry.
    /// Snapshots with neither cwd nor url fall back to "app:<name>".
    static func cluster(_ snapshots: [Snapshot]) -> [Context] {
        var byKey: [String: Accumulator] = [:]

        for snapshot in snapshots {
            let key: String
            let label: String
            if let url = snapshot.url, !url.isEmpty {
                key = url
                label = snapshot.title?.isEmpty == false ? snapshot.title! : url
            } else if let cwd = snapshot.cwd, !cwd.isEmpty {
                let process = snapshot.processName ?? "shell"
                key = "\(cwd)::\(process)"
                label = (cwd as NSString).lastPathComponent
            } else if let app = snapshot.app {
                key = "app:\(app)"
                label = app
            } else {
                continue
            }

            var entry = byKey[key] ?? Accumulator(cwd: snapshot.cwd, label: label, lastSeen: .distantPast)
            entry.sources.insert(snapshot.source)
            // lastSeen drives switcher ordering, so it must mean "last genuinely focused,"
            // not "last observed to exist" — otherwise every open tab gets bumped to "now"
            // on every poll just for being open, and whichever collector happens to run
            // last in the tick wins the recency sort regardless of actual attention.
            if snapshot.isActiveNow {
                entry.lastSeen = max(entry.lastSeen, snapshot.timestamp)
            }

            // Multiple tabs can still land in the same bucket (e.g. two idle shells in
            // the same dir); prefer whichever is actually selected in its window when
            // picking the representative tty/url to jump to.
            let priority = snapshot.isFrontmostTab ? 1 : 0
            let isBetter = priority > entry.representativePriority
                || (priority == entry.representativePriority && snapshot.timestamp >= entry.representativeTimestamp)
            if isBetter {
                entry.representativePriority = priority
                entry.representativeTimestamp = snapshot.timestamp
                if let app = snapshot.app {
                    entry.app = app
                }
                entry.tty = snapshot.tty
                entry.processName = snapshot.processName
                entry.url = snapshot.url
            }
            byKey[key] = entry
        }

        return byKey.map { key, value in
            Context(
                id: key,
                cwd: value.cwd,
                label: value.label,
                summary: nil,
                lastSeen: value.lastSeen,
                sources: value.sources,
                app: value.app.isEmpty ? value.label : value.app,
                tty: value.tty,
                processName: value.processName,
                url: value.url
            )
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }
}
