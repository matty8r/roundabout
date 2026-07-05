# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Breadcrumbs is a macOS menu-bar app (Swift Package, not an Xcode project) that tracks the user's actual working "contexts" — which Terminal tab/process, which Safari tab, which app — and provides an Option-Tab / Option-Shift-Tab switcher (styled with real Liquid Glass, `NSGlassEffectView`) that jumps straight back into the selected context, not just the app.

## Commands

Build:
```
swift build
```

Package as a `.app` bundle (**required** before testing anything that needs Accessibility or Automation permissions — macOS will not reliably grant those to a raw `.build/debug/Breadcrumbs` executable, only to a proper bundle):
```
./scripts/build_app.sh [debug|release]   # defaults to debug
```

Run (kill any existing instance first; launch from a shell so the process inherits `ANTHROPIC_API_KEY` — a GUI-launched build won't see shell env vars at all):
```
pkill -f "Breadcrumbs" 2>/dev/null
./scripts/build_app.sh debug
source .env   # loads ANTHROPIC_API_KEY (gitignored, not in shell rc)
nohup ./Breadcrumbs.app/Contents/MacOS/Breadcrumbs > /tmp/breadcrumbs.log 2>&1 &
disown
```

There is no test target. Verification is done live: check `/tmp/breadcrumbs.log` (all diagnostics go to stderr) and query the SQLite store directly, e.g.:
```
sqlite3 ~/Library/Application\ Support/Breadcrumbs/breadcrumbs.sqlite3 "SELECT source, app, cwd, url, is_active_now FROM snapshots ORDER BY id DESC LIMIT 20;"
```

Whenever the SQLite schema changes (a new column added to `SnapshotStore`), delete the on-disk database before relaunching, or old rows will read back with the new fields defaulted/null and produce confusing results:
```
rm -f ~/Library/Application\ Support/Breadcrumbs/breadcrumbs.sqlite3
```

## Architecture

Data flow: **Collectors → SnapshotStore (SQLite) → ContextClusterer → ClaudeSummarizer (async, gated) → StatusItemController (menu) + SwitcherWindowController (Option-Tab overlay) → ContextActivator (jump back)**. `AppDelegate` owns all of it: a 15s poll `Timer` driving `tick()`, the store, the hotkey manager, the switcher controller, and the summary cache/in-flight tracking.

**Collectors** (`Sources/Breadcrumbs/Collectors/`) each produce `[Snapshot]` from one signal source:
- `FrontmostAppCollector` — `NSWorkspace.frontmostApplication`; inherently "active" whenever it fires, since it only ever reports the current frontmost app.
- `TerminalCollector` — AppleScript enumerates Terminal windows/tabs; resolves each tty's cwd and foreground process via `ps`/`lsof`.
- `SafariCollector` — AppleScript enumerates Safari windows/tabs (URL, title); gated on Safari already running so polling doesn't launch it.

Both AppleScript collectors share two non-obvious gotchas, already the cause of two separate bugs — don't reintroduce them:
- Inside `tell application "Terminal"` / `"Safari"`, the bare `tab` keyword is shadowed by the app's own "tab" (window/browser tab) scripting noun and silently stringifies to the literal text `"tab"` instead of a tab character. Use `(ASCII character 9)` for delimiters.
- AppleScript's `is` operator for object identity does not reliably compare two separately-fetched references to the same tab/window (e.g. `t is (selected tab of w)` can evaluate false even when `t` genuinely is the selected tab). Compare by a concrete value instead — tty string, tab `index`, window `id`.

**`Snapshot`** (`Models/Snapshot.swift`) is the raw per-poll record. The important field is `isActiveNow`: true only when the snapshot is the system's frontmost app's frontmost window's selected tab *at that poll*. This is what drives switcher ordering — treating "was observed to exist" as "recently used" (the original bug) means every open tab gets bumped to "now" every poll and whichever collector happens to run last in `tick()` wins the recency sort regardless of actual attention.

**`SnapshotStore`** (`Storage/SnapshotStore.swift`) is an append-only SQLite log at `~/Library/Application Support/Breadcrumbs/breadcrumbs.sqlite3`, using the raw C SQLite3 API (no ORM). Every field on `Snapshot` must be threaded through `CREATE TABLE`, `INSERT`, and `SELECT` by hand — a field added to the Swift struct but not the SQL layer silently reads back as nil/default with no compile error (has already happened once, with `processName`/`isActiveNow`).

**`ContextClusterer`** (`Clustering/ContextClusterer.swift`) groups snapshots into `Context`s by key: `cwd::processName` for terminal snapshots (so an idle shell and an active `claude` session in the same directory become distinct contexts, not one merged/ambiguous one), the page `url` for Safari tabs, `app:<name>` as the fallback. `lastSeen` only advances on `isActiveNow == true` snapshots. It also tracks a "representative" tty/url per key (preferring the currently-selected tab) for `ContextActivator` to jump to.

**`ClaudeSummarizer`** (`Summarizer/ClaudeSummarizer.swift`) makes raw HTTPS calls to the Anthropic Messages API (no official Swift SDK exists) using structured output (`output_config.format` / `json_schema`) to get back `{name, summary}`. Uses `claude-haiku-4-5` deliberately, for cost, since it fires on live/changing contexts. Reads `ANTHROPIC_API_KEY` from the process environment. Two entry points:
- `summarize(cwd:label:)` — reads the matching Claude Code session transcript from `~/.claude/projects/-<sanitized-cwd>/` via `TranscriptReader`.
- `summarizeWebPage(title:excerpt:)` — takes page text fetched by `SafariCollector.fetchPageText` (`do JavaScript` in the matched tab — requires the user to enable Safari's Develop menu → "Allow JavaScript from Apple Events"; without it, this fails loudly to stderr rather than silently no-opping).

`AppDelegate.refreshAndRender()` decides *when* to call these, not the summarizer itself: terminal contexts only when `processName == "claude"` (an idle shell sharing a cwd with an active session would otherwise inherit that session's misleading summary); Safari contexts only when their cheap title collides with another open tab's title (no point spending a call on an already-distinguishable tab).

**`ContextActivator`** (`Collectors/ContextActivator.swift`) is "jump to this context": AppleScript to select the exact Terminal tab (by tty) or Safari tab (by URL) and bring its window forward, or `NSRunningApplication.activate()` for app-only fallback contexts.

**`HotkeyManager`** (`Hotkey/HotkeyManager.swift`) is a `CGEventTap`-based global listener for Option-Tab (cycle) and Option-Shift-Tab (cycle backward) — Cmd-Tab itself can't be intercepted since the system owns it. Requires Accessibility trust (`AXIsProcessTrustedWithOptions`); the tap silently produces nothing without it.

**`SwitcherWindowController` / `ContextRowView`** (`Switcher/`) render the Option-Tab overlay: a borderless `NSPanel` containing a single top-level `NSGlassEffectView` (real Liquid Glass — macOS 26+ only, which is why `Package.swift` targets `.macOS(.v26)`). Rows are NOT nested glass views (unsupported z-ordering per Apple's docs) — highlighting is a plain layered `CALayer`. Rows size themselves (summaries wrap instead of truncating), so panel height comes from `stack.fittingSize`, clamped to 85% of screen height.

**Packaging**: this is a Swift Package executable, not an Xcode project, so there's no `.app` bundle by default — `scripts/build_app.sh` assembles one (`Resources/Info.plist`, ad-hoc `codesign`) after every build. Permissions (Accessibility, Safari Automation) must be granted to that bundle, not the raw binary.

**Swift language mode**: `Package.swift` pins `swiftLanguageModes: [.v5]` despite `swift-tools-version:6.2` — the newer tools version is needed for the `.v26` platform case, but Swift 6's default strict-concurrency checking would otherwise force `@MainActor` annotations through this AppKit-heavy, effectively single-threaded codebase.

## Future possibilities (not yet implemented)

- **Apple Intelligence / `FoundationModels` framework** as a summarization backend alternative to the Claude API — on-device, free, private, no API key required, but a much smaller model than Haiku (quality tradeoff), and requires Apple Intelligence enabled on the user's Mac.
- **User-selectable LLM provider** for non-Claude users.
- **Shipping a bundled lightweight local model (e.g. Gemma)** as a no-setup-required default.
- Additional browser support: Chrome/Arc are cheap to add (same AppleScript dictionary shape as Safari — windows/tabs/URL/title). Firefox has no AppleScript scripting dictionary at all and would need a browser extension + native messaging host — a materially bigger project.
- iTerm2 support (richer AppleScript API than Terminal.app) if the user switches terminal emulators.
