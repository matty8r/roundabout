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

    /// The clustering key for a single snapshot — exposed so callers can compute "is this
    /// specific context still actually open right now" independent of the historical
    /// clustering pass (see AppDelegate's existence-pruning against fresh per-tick snapshots).
    static func key(for snapshot: Snapshot) -> String? {
        if let url = snapshot.url, !url.isEmpty {
            return url
        } else if let cwd = snapshot.cwd, !cwd.isEmpty {
            let process = snapshot.processName ?? "shell"
            return "\(cwd)::\(process)"
        } else if let app = snapshot.app {
            return "app:\(app)"
        }
        return nil
    }

    /// One context per (cwd, foreground process) for terminal snapshots, one per url
    /// for browser tabs — so an idle shell and an active Claude session in the same
    /// directory (or two different browser tabs) don't get merged into one entry.
    /// Snapshots with neither cwd nor url fall back to "app:<name>".
    static func cluster(_ snapshots: [Snapshot]) -> [Context] {
        var byKey: [String: Accumulator] = [:]

        for snapshot in snapshots {
            guard let key = key(for: snapshot) else { continue }
            let label: String
            if let url = snapshot.url, !url.isEmpty {
                label = snapshot.title?.isEmpty == false ? snapshot.title! : url
            } else if let cwd = snapshot.cwd, !cwd.isEmpty {
                let dirName = (cwd as NSString).lastPathComponent
                // A claude session gets a stable "<dir> — Claude" label here specifically so
                // AppDelegate.refreshAndRender() can leave it alone once a summary arrives —
                // only .summary should update as the AI re-describes what's happening; the
                // header itself needs to stay put as something to visually grab onto, rather
                // than reflecting whatever 2-4 word name the model picked for this round.
                label = snapshot.processName == "claude" ? "\(dirName) — Claude" : dirName
            } else {
                label = snapshot.app ?? key
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
