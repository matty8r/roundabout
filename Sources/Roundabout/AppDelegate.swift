import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SnapshotStore()
    private let statusItemController = StatusItemController()
    private var pollTimer: Timer?
    private var accessibilityPollTimer: Timer?

    private var summaryCache: [String: (result: SummarizerResult, cachedAt: Date)] = [:]
    private let summaryTTL: TimeInterval = 5 * 60
    private var inFlightSummaries: Set<String> = []

    private let claudeSummarizer = ClaudeSummarizer()
    private let foundationModelsSummarizer = FoundationModelsSummarizer()

    /// Resolved fresh on every call (not cached as a stored reference) so flipping the
    /// status-bar menu's "Summarization" selection takes effect on the very next pass,
    /// without needing a relaunch.
    private var activeSummarizer: any Summarizer {
        switch SummarizerPreferenceStore.current {
        case .onDevice:
            return foundationModelsSummarizer
        case .anthropic:
            return claudeSummarizer
        }
    }

    private let pollInterval: TimeInterval = 15
    private let clusteringWindow: TimeInterval = 30 * 60

    private var latestContexts: [Context] = []
    private let hotkeyManager = HotkeyManager()
    private let switcher = SwitcherWindowController()

    // The most recent full collection, used to prune closed tabs/apps on *every*
    // render — not just the render that did the collecting. Without this, a render
    // triggered by something other than a full tick (a summary finishing async, or
    // the instant app-switch notification) skipped pruning entirely, which could
    // silently "revive" a just-closed tab/app until the next 15s poll happened to land.
    private var lastFreshSnapshots: [Snapshot] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Clicking a context row in the status-bar dropdown jumps to it exactly like
        // selecting it in the Option-Tab overlay does — same activate + recency-bump pair.
        statusItemController.onSelectContext = { [weak self] context in
            guard let self else { return }
            ContextActivator.activate(context)
            self.markActivated(context)
        }

        // Switching summarization providers should be felt immediately, not after the
        // existing 5-minute cache entries happen to expire.
        statusItemController.onSummarizerPreferenceChanged = { [weak self] in
            guard let self else { return }
            self.summaryCache.removeAll()
            self.refreshAndRender()
        }

        // Unconditional, so every launch — success or failure, manual or via login
        // item — leaves durable evidence of what happened. Without this, a launch
        // that hits no error path (the common case) writes nothing at all, which
        // makes "did it even start" indistinguishable from "log file doesn't exist yet."
        let trusted = HotkeyManager.ensureAccessibilityPermission()
        Log.write("Roundabout launched (pid \(ProcessInfo.processInfo.processIdentifier)); accessibility trusted = \(trusted)\n")

        if trusted {
            setUpHotkey()
        } else {
            Log.write("Accessibility permission not yet granted — waiting for it to be granted in System Settings (no relaunch needed once you do).\n")
            waitForAccessibilityPermission()
        }

        // 15s polling alone can miss an app you only glance at briefly (open it, do
        // something, switch away in under 15s) — it can fall entirely between two
        // ticks and never get recorded. This fires instantly on every app switch.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick() // run immediately on launch
    }

    @objc private func appActivated(_ notification: Notification) {
        // .regular excludes system/background agents — see FrontmostAppCollector's
        // comment on the same filter for the poll path. Terminal/Safari are excluded for
        // the same reason FrontmostAppCollector excludes them: they have dedicated
        // collectors already, so a generic snapshot here would just create a redundant
        // "app:Terminal"/"app:Safari" context alongside the real tab-specific one.
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              let name = app.localizedName,
              !FrontmostAppCollector.isCoveredByDedicatedCollector(name) else { return }
        store.insert(Snapshot(
            source: "frontmost", app: name, title: nil, cwd: nil, tty: nil,
            timestamp: Date(), isActiveNow: true
        ))
        refreshAndRender()
    }

    private func setUpHotkey() {
        hotkeyManager.onOptionTab = { [weak self] reverse in
            guard let self else { return }
            if self.switcher.isVisible {
                reverse ? self.switcher.retreat() : self.switcher.advance()
            } else {
                self.switcher.show(contexts: self.latestContexts, reverse: reverse)
            }
        }
        hotkeyManager.onOptionReleased = { [weak self] in
            guard let self, self.switcher.isVisible else { return }
            if let selected = self.switcher.commitAndHide() {
                ContextActivator.activate(selected)
                self.markActivated(selected)
            }
        }
        hotkeyManager.start()
    }

    /// Accessibility trust is normally only checked once, at launch — if it's missing then,
    /// the hotkey silently never starts, and previously the only way to pick up a permission
    /// grant made afterward was to quit and relaunch. This polls until AXIsProcessTrusted()
    /// goes true and starts the hotkey right then, so granting it in System Settings while
    /// Roundabout is already running is enough on its own. (Ad-hoc signing can still mean the
    /// System Settings toggle doesn't visibly "take" until the existing entry is removed and
    /// re-added rather than just switched on — see CLAUDE.md's Packaging section — but once it
    /// does take, this notices within a couple of seconds instead of requiring a relaunch.)
    private func waitForAccessibilityPermission() {
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard HotkeyManager.isAccessibilityTrusted() else { return }
            timer.invalidate()
            self.accessibilityPollTimer = nil
            Log.write("Accessibility permission granted while running — starting hotkey now.\n")
            self.setUpHotkey()
        }
    }

    /// Marks a context as just-activated so switcher ordering reflects it immediately,
    /// rather than waiting for the next 15s poll (or, for Terminal/Safari, indefinitely —
    /// appActivated doesn't track them; see FrontmostAppCollector). Without this, a quick
    /// single Option-Tab tap — mirroring Cmd-Tab's "jump straight back to what I was just
    /// in" gesture — wouldn't reliably ping-pong on a second tap: `latestContexts` would
    /// still show the context we just left as "most recent", since nothing else updates
    /// its lastSeen until the next poll notices it's frontmost again.
    private func markActivated(_ context: Context) {
        store.insert(Snapshot(
            source: "activation", app: context.app, title: nil, cwd: context.cwd, tty: context.tty,
            timestamp: Date(), isFrontmostTab: true, processName: context.processName, url: context.url,
            isActiveNow: true
        ))
        refreshAndRender()
    }

    private func tick() {
        var fresh: [Snapshot] = []
        if let snapshot = FrontmostAppCollector.collect() {
            store.insert(snapshot)
            fresh.append(snapshot)
        }
        let terminalSnapshots = TerminalCollector.collect()
        terminalSnapshots.forEach(store.insert)
        fresh.append(contentsOf: terminalSnapshots)

        let safariSnapshots = SafariCollector.collect()
        safariSnapshots.forEach(store.insert)
        fresh.append(contentsOf: safariSnapshots)

        lastFreshSnapshots = fresh
        refreshAndRender()
    }

    private func refreshAndRender() {
        let recent = store.recentSnapshots(since: Date().addingTimeInterval(-clusteringWindow))
        var contexts = ContextClusterer.cluster(recent)

        // Prune contexts whose tab/window/app no longer actually exists — using the
        // last full collection (not necessarily from this call) so a render triggered
        // by something other than a poll tick still prunes correctly.
        let openKeys = Set(lastFreshSnapshots.compactMap(ContextClusterer.key(for:)))
        contexts = contexts.filter { context in
            if openKeys.contains(context.id) { return true }
            if context.id.hasPrefix("app:") {
                // No collector enumerates "all open apps" every tick, so an app-fallback
                // context is judged by whether the app is still running at all, not
                // whether it was the last tick's frontmost app.
                return NSWorkspace.shared.runningApplications.contains { $0.localizedName == context.app }
            }
            // A terminal/Safari context whose key wasn't in the last fresh collection
            // means that specific tab/window no longer exists — drop it immediately
            // rather than letting it linger for the rest of the history window.
            return false
        }

        // Apply any cached summaries we already have, then render immediately
        // so the menu updates with cheap labels before the network calls return.
        for i in contexts.indices {
            if let cached = summaryCache[contexts[i].id], Date().timeIntervalSince(cached.cachedAt) < summaryTTL {
                contexts[i].summary = cached.result.summary
                // Terminal contexts keep the stable "<dir> — Claude" label ContextClusterer
                // already gave them — only the summary should change as work progresses, so
                // there's a consistent header to recognize the context by. Safari contexts
                // still adopt the AI-generated name: there it's specifically there to
                // disambiguate same-titled tabs, which needs the visible title to actually change.
                if contexts[i].cwd == nil {
                    contexts[i].label = cached.result.name
                }
            }
        }
        statusItemController.render(contexts: contexts)
        latestContexts = contexts

        // Kick off async summarization for anything stale/uncached, one at a time per key.
        for context in contexts {
            let isStale = summaryCache[context.id].map { Date().timeIntervalSince($0.cachedAt) >= summaryTTL } ?? true
            guard isStale, !inFlightSummaries.contains(context.id) else { continue }

            if let cwd = context.cwd, context.processName == "claude" {
                // Only summarize terminal contexts actively running a Claude Code session —
                // summarization is keyed by directory, so an idle shell sharing a cwd with an
                // active session would otherwise inherit that session's (misleading) summary.
                inFlightSummaries.insert(context.id)
                let summarizer = activeSummarizer // resolved once per request, not inside the Task —
                // a mid-flight provider switch shouldn't change which backend a request finishes with.
                Task { [weak self] in
                    guard let self else { return }
                    let result = await summarizer.summarize(cwd: cwd, label: context.label)
                    await self.finishSummarizing(context.id, result: result)
                }
            } else if let url = context.url {
                // Every Safari tab gets summarized now, not just ones whose title collides
                // with another open tab's — on-device summarization (the default) is free,
                // so there's no cost reason left to hold back, and the extra context (domain
                // + one-line summary) is useful even for an already-distinguishable tab.
                inFlightSummaries.insert(context.id)
                let summarizer = activeSummarizer
                Task { [weak self] in
                    guard let self else { return }
                    var summarized: SummarizerResult?
                    if let pageText = SafariCollector.fetchPageText(forURL: url) {
                        summarized = await summarizer.summarizeWebPage(title: context.label, excerpt: pageText)
                    }
                    await self.finishSummarizing(context.id, result: summarized)
                }
            }
        }
    }

    @MainActor
    private func finishSummarizing(_ contextId: String, result: SummarizerResult?) {
        inFlightSummaries.remove(contextId)
        if let result {
            Log.write("Summarized \(contextId) -> \"\(result.name)\": \(result.summary)\n")
            summaryCache[contextId] = (result, Date())
            refreshAndRender() // re-render with the fresh summary; still prunes via lastFreshSnapshots
        } else {
            Log.write("No summary for \(contextId)\n")
        }
    }
}
