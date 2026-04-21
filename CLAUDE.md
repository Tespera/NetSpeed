# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

NetSpeed is a macOS menu-bar network monitor. Pure Swift + system frameworks, zero third-party dependencies, built with Swift Package Manager. Runs as an `LSUIElement` agent (no Dock icon).

- Platform target: macOS 13+ (see `Package.swift`)
- Executable target `NetSpeed` with sources under `Sources/` (`Assets/` is excluded from the build)
- Ships as `NetSpeed.app` assembled by the packaging script — not Xcode

## Commands

```bash
swift build                    # debug build
swift build -c release         # release build (required before packaging)
swift run                      # run debug build directly
swift test                     # currently no tests exist

./tools/package_app.sh         # release build + assemble NetSpeed.app bundle
```

`package_app.sh` runs `swift build -c release`, writes `NetSpeed.app/Contents/Info.plist` inline (heredoc), copies the release binary into `Contents/MacOS/`, and copies `Sources/Assets/AppIcon.icns` if present. The committed `NetSpeed.app/` is a packaging artifact — regenerate it with the script rather than hand-editing.

When iterating, prefer `swift run` over launching the `.app`; the `.app` is only needed to test LaunchAgent install or `LSUIElement` behavior.

## Architecture

Four Swift files, each with a single responsibility:

- **`Sources/NetSpeedApp.swift`** — `@main` entry point. Creates the `NSApplication`, installs `AppDelegate` as the delegate, calls `app.run()`. Kept deliberately thin.

- **`Sources/AppDelegate.swift`** — The controller. Owns the `NSStatusItem`, builds the menu, drives the polling `Timer` via Combine, manages the per-process submenu, and handles LaunchAgent install/remove. This is where almost all behavior lives.

- **`Sources/NetSpeedMonitor.swift`** — Byte-counter sampler. Walks `getifaddrs` for `AF_LINK` entries, reads `if_data.ifi_{i,o}bytes`, and computes up/down rates against the previous sample. Two scopes: `.primary` (only the interface reported by `SCDynamicStore` under `State:/Network/Global/IPv{4,6}`) or `.all` (everything except `lo0`). All mutable state is guarded by a concurrent `DispatchQueue` with barrier writes — treat the public getters/setters as the only safe access path; do not read the underscore-prefixed stored properties directly from outside `refresh(...)`.

- **`Sources/NetSpeedStatusView.swift`** — Custom `NSView` hosted inside `statusItem.button`. Draws two stacked monospaced-digit lines (up / down) with optional `↑` / `↓` glyphs and per-glyph kerning. The status item uses a fixed pixel length (`42` without arrows, `48` with) rather than auto-sizing.

### Rate pipeline (AppDelegate ↔ NetSpeedMonitor)

1. `AppDelegate.restartTimer()` publishes a `Timer` at `updateInterval` on `.main`.
2. Each tick calls `monitor.refresh { … }`. Refresh runs on the monitor's private queue, then hops the completion to `.main`.
3. The main-thread completion calls `updateStatusBar()` and applies **adaptive refresh with hysteresis**:
   - switch to `0.5s` when `max(up, down) >= 1.1 MiB/s` (`fastThreshold`)
   - switch back to `1.0s` when `max(up, down) <= 0.9 MiB/s` (`slowThreshold`)
   - The two thresholds intentionally differ — do not collapse them into one value; it's there to prevent flapping.
4. Inside `refresh`, the monitor keeps a 5-sample history per direction and averages over **1 sample** when the latest value is ≥ 1 MiB/s (responsive) or the **last 3 samples** when below (smoothing). The README claims SI units (1 KB = 1000 B), but the code uses binary units (`1024`) in both the threshold check and `formatSpeed`; match the code, not the README, when making changes here.

### Per-process submenu

The "Processes" submenu is populated on demand (`NSMenuDelegate.menuWillOpen`) and polled every 1s while open:

- Data source is `/usr/bin/nettop -P -x -l 1` parsed via regex (`^(\S+)\s+(.+)\.(\d+)\s+(\d+)\s+(\d+)`). `nettop` prints cumulative totals, so `AppDelegate` keeps `previousProcTotals` to compute deltas, and wipes it on each `menuWillOpen` so the first sample in a session shows 0 rather than a huge spike.
- Rows are fixed-size custom `NSView`s (`ProcessItemView`) pre-built once in `setupMenu()` and updated in place — don't rebuild the menu on each tick. Clicking a row opens the app's bundle in Finder via `NSWorkspace.activateFileViewerSelecting`.
- Icons/names resolve via `NSWorkspace.runningApplications` first, then `proc_pidpath` + `NSWorkspace.icon(forFile:)` as a fallback.

### LaunchAgent (Launch at Login)

Implemented by writing `~/Library/LaunchAgents/com.netspeed.NetSpeed.plist` with `RunAtLoad=true`, `KeepAlive=true`, `ProcessType=Background`, then shelling out to `/bin/launchctl bootstrap`/`enable`/`kickstart` against `gui/$UID`. Removal is `disable` + `bootout` + file delete. `ProgramArguments` points at `Bundle.main.executablePath`, so "Launch at Login" only works reliably when running from an installed `.app` (not from `swift run`).

## Conventions

- Zero third-party dependencies is a design invariant — don't add any to `Package.swift`.
- Swift-only, system frameworks only (`Cocoa`, `Combine`, `SystemConfiguration`, `Darwin`).
- README.md and README_EN.md are kept in sync (Chinese ↔ English); update both when changing user-facing behavior.
