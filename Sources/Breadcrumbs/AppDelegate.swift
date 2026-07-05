import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SnapshotStore()
    private let statusItemController = StatusItemController()
    private var pollTimer: Timer?

    private var summaryCache: [String: (result: ClaudeSummarizer.Result, cachedAt: Date)] = [:]
    private let summaryTTL: TimeInterval = 5 * 60
    private var inFlightSummaries: Set<String> = []

    private let pollInterval: TimeInterval = 15
    private let clusteringWindow: TimeInterval = 30 * 60

    private var latestContexts: [Context] = []
    private let hotkeyManager = HotkeyManager()
    private let switcher = SwitcherWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if HotkeyManager.ensureAccessibilityPermission() {
            setUpHotkey()
        } else {
            fputs("Accessibility permission not yet granted — grant it in System Settings, then relaunch Breadcrumbs.\n", stderr)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick() // run immediately on launch
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
            }
        }
        hotkeyManager.start()
    }

    private func tick() {
        if let snapshot = FrontmostAppCollector.collect() {
            store.insert(snapshot)
        }
        for snapshot in TerminalCollector.collect() {
            store.insert(snapshot)
        }
        for snapshot in SafariCollector.collect() {
            store.insert(snapshot)
        }
        refreshAndRender()
    }

    private func refreshAndRender() {
        let recent = store.recentSnapshots(since: Date().addingTimeInterval(-clusteringWindow))
        var contexts = ContextClusterer.cluster(recent)

        // Apply any cached summaries we already have, then render immediately
        // so the menu updates with cheap labels before the network calls return.
        for i in contexts.indices {
            if let cached = summaryCache[contexts[i].id], Date().timeIntervalSince(cached.cachedAt) < summaryTTL {
                contexts[i].summary = cached.result.summary
                contexts[i].label = cached.result.name
            }
        }
        statusItemController.render(contexts: contexts)
        latestContexts = contexts

        // A Safari tab's title is only worth spending an API call on when it collides
        // with another open tab's title — e.g. several generic same-named app tabs
        // (Krea, ChatGPT, ...) that the cheap label can't tell apart.
        var safariLabelCounts: [String: Int] = [:]
        for context in contexts where context.url != nil {
            safariLabelCounts[context.label, default: 0] += 1
        }

        // Kick off async summarization for anything stale/uncached, one at a time per key.
        for context in contexts {
            let isStale = summaryCache[context.id].map { Date().timeIntervalSince($0.cachedAt) >= summaryTTL } ?? true
            guard isStale, !inFlightSummaries.contains(context.id) else { continue }

            if let cwd = context.cwd, context.processName == "claude" {
                // Only summarize terminal contexts actively running a Claude Code session —
                // summarization is keyed by directory, so an idle shell sharing a cwd with an
                // active session would otherwise inherit that session's (misleading) summary.
                inFlightSummaries.insert(context.id)
                Task { [weak self] in
                    guard let self else { return }
                    let result = await ClaudeSummarizer.summarize(cwd: cwd, label: context.label)
                    await self.finishSummarizing(context.id, result: result)
                }
            } else if let url = context.url, (safariLabelCounts[context.label] ?? 0) > 1 {
                inFlightSummaries.insert(context.id)
                Task { [weak self] in
                    guard let self else { return }
                    var summarized: ClaudeSummarizer.Result?
                    if let pageText = SafariCollector.fetchPageText(forURL: url) {
                        summarized = await ClaudeSummarizer.summarizeWebPage(title: context.label, excerpt: pageText)
                    }
                    await self.finishSummarizing(context.id, result: summarized)
                }
            }
        }
    }

    @MainActor
    private func finishSummarizing(_ contextId: String, result: ClaudeSummarizer.Result?) {
        inFlightSummaries.remove(contextId)
        if let result {
            fputs("Summarized \(contextId) -> \"\(result.name)\": \(result.summary)\n", stderr)
            summaryCache[contextId] = (result, Date())
            refreshAndRender() // re-render with the fresh summary, no re-collection
        } else {
            fputs("No summary for \(contextId)\n", stderr)
        }
    }
}
