# Roundabout

A macOS menu-bar app that remembers your actual working **contexts** — not just which app you were using, but which Terminal tab, which Safari tab, which specific window — and jumps straight back into one with a single Option-Tab gesture, the same way Cmd-Tab jumps back to your last app.

<p align="center">
  <img src="Resources/AppIcon.svg" width="120" alt="Roundabout icon">
</p>

## Why

Cmd-Tab switches between apps. If you spend your day in one Terminal window with a dozen tabs and a browser with a dozen tabs, "switch to Terminal" or "switch to Safari" isn't specific enough — you still have to hunt for the right tab. Roundabout treats each tab/window as its own context, tracks which one you were actually paying attention to (not just which ones happen to be open), and lets Option-Tab jump back to a specific one directly.

## Features

- **Option-Tab / Option-Shift-Tab** — a Liquid-Glass overlay switcher that cycles through your recent contexts and jumps straight back into the selected one on release, mirroring Cmd-Tab's gesture.
- **Per-tab awareness** for Terminal (tracks cwd + foreground process, so an idle shell and an active `claude` session in the same directory are distinct contexts) and Safari (tracks URL + title).
- **Menu-bar dropdown** showing your current contexts — click any row to jump to it directly, no keyboard required.
- **Optional AI-generated summaries**: a one-line description of what you're actually doing in a context (e.g. summarizing what a Claude Code session is working on, or disambiguating several same-titled browser tabs), powered by the Anthropic API.
- **Runs as a login item** — set it and forget it; no need to launch it by hand each session.

## Requirements

- macOS 26 or later (uses `NSGlassEffectView` for real Liquid Glass, and `SMAppService` for login-item registration)
- A Swift 6.2+ toolchain to build from source (Xcode 26+, or the corresponding Swift toolchain)

## Building

This is a Swift Package, not an Xcode project:

```sh
swift build
```

To actually run it, package it as a proper `.app` bundle — macOS won't reliably grant Accessibility/Automation permissions to a raw command-line binary:

```sh
./scripts/build_app.sh [debug|release]   # defaults to debug
```

This assembles `Roundabout.app`, generates the app icon from `Resources/AppIcon.svg`, and ad-hoc signs the bundle.

## Installing

Copy the built app into `/Applications` and launch it:

```sh
rm -rf /Applications/Roundabout.app
cp -R Roundabout.app /Applications/Roundabout.app
open /Applications/Roundabout.app
```

On first launch it will prompt for:

- **Accessibility** — required for the global Option-Tab hotkey to work at all.
- **Automation** (Terminal, then Safari) — required the first time each app's tabs are enumerated via AppleScript.

Look for the roundabout-sign icon in your menu bar once it's running. From that menu you can also turn on **Launch at Login** so it starts automatically going forward.

> Because the app is ad-hoc signed (no paid Developer ID), macOS may ask you to re-grant Accessibility/Automation permissions after rebuilding — this is expected and not a bug.

## AI-generated summaries (optional)

To enable short, LLM-generated descriptions of what you're working on in each context, click the menu bar icon → **Set Anthropic API Key…** and paste in an API key from the [Anthropic Console](https://console.anthropic.com/settings/keys). The key is stored in the macOS Keychain, so it works regardless of how the app was launched (including as a login item). Without a key, Roundabout still works fully — contexts just use their cheap default label (directory name, page title, or app name) instead of a generated summary.

## How it works

Collectors poll (and react instantly to app switches) to build a log of "snapshots" — one per Terminal tab, Safari tab, or frontmost app — stored in a local SQLite database. These get clustered into distinct contexts, ordered by genuine recency of attention (not just "was open"), and rendered into both the menu-bar dropdown and the Option-Tab overlay. See [`CLAUDE.md`](CLAUDE.md) for the full architecture writeup, including the non-obvious AppleScript/AppKit gotchas encountered along the way.

There's no test target — verification is done live, by checking the durable log at `~/Library/Application Support/Roundabout/roundabout.log` and querying the SQLite store directly. Details in `CLAUDE.md`.

## Roadmap

Not yet implemented, but plausible next steps:

- On-device summarization via Apple's `FoundationModels` framework, as a free/private alternative to the Claude API
- Chrome/Arc support alongside Safari
- iTerm2 support alongside Terminal.app
