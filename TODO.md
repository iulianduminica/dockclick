# DockClick TODO

Status legend:
- [ ] Planned
- [x] Done
- [~] In progress

Conventions:
- Only the top-level checkbox indicates completion. Avoid trailing “- [x] Done” lines.
- Use a short “Status:” line to capture notes or partial progress.
- Keep acceptance criteria explicit so features remain testable.

## Critical

- [x] Fix Accessibility prompt options dictionary
  - File: main.swift -> startEventMonitoring()
  - Implemented correct bridging: `kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String` with `AXIsProcessTrustedWithOptions`
  - Acceptance: App prompts correctly on first launch; no CF bridging warnings.

- [x] Handle event tap disable events immediately
  - File: main.swift -> startEventMonitoring() callback
  - Re-enable on `.tapDisabledByTimeout` and `.tapDisabledByUserInput`; removed 5s polling timer.
  - Acceptance: No missed clicks; timer removed; tap reliably re-enables.

- [x] Correct Dock coordinate system usage
  - File: main.swift -> updateDockItems()
  - Flip Y from AX top-left to AppKit bottom-left using main screen height.
  - Acceptance: Click hit-testing works at bottom dock on single-monitor.

## High

- [x] Filter only application dock tiles
  - Source: AppleScript currently returns all list items.
  - Added `subrole` retrieval; include only `AXApplicationDockItem`.
  - Acceptance: System items (Trash/Downloads/Folders) excluded without name heuristics.

- [x] Multi-display and dock position support
  - Detect dock orientation (bottom/left/right) and target screen; adjust coordinate conversion.
  - Acceptance: Hit-testing correct with dock on left/right and with external monitor.
  - Status: Done — union dock bounds, dock screen detection, inferred orientation when missing, on-screen intersection for bounds, directional hit expansion, and candidate filtering to dock on-screen area.

- [x] Replace AppleScript with Accessibility API (AX) traversal of Dock
  - Implemented AX traversal starting at Dock app, collecting `AXApplicationDockItem` tiles with frames.
  - Falls back to AppleScript when AX is not trusted or fails.
  - Acceptance: Faster updates; fewer permissions prompts when Accessibility is granted.

- [x] Thread-safe access to `dockItems`
  - Guarantee access only on main thread or migrate to an `actor`.
  - Acceptance: No possible races if event tap is moved off main run loop.
  - Status: UI/state methods marked `@MainActor`; event tap callback dispatches to main-isolated methods; background tasks avoid reading main-actor state.

- [x] Improve running app resolution
  - Avoid name heuristics; prefer bundle identifiers from dock tile or associated app.
  - Acceptance: Correctly matches apps with short names (e.g., “Code”).
  - Status: Exact-name match preferred; then resolve bundle id via workspace/bundle; then select running apps by bundle id; finally fallback to refined scoring with common aliases.

## Medium

- [x] Build script harden and explicit linking
  - File: build.sh
  - Added `set -euo pipefail`; link frameworks explicitly for both icon generator and main:
    - `-framework Cocoa -framework ApplicationServices -framework UserNotifications -framework ServiceManagement`
  - Acceptance: Deterministic builds; early exit on errors.

- [x] Notifications and Accessibility settings shortcuts
  - File: main.swift (menu)
  - Added menu items to open the relevant System Settings panes via URL schemes.

- [x] Debug logging default off + toggle
  - File: main.swift
  - Added menu toggle with persistence via `UserDefaults` (key: `DebugMode`).
  - Acceptance: Quiet by default; can toggle at runtime and persists.

- [x] Login Items via helper target
  - Replace `SMAppService.mainApp` with a proper `SMLoginItem` helper app.
  - Acceptance: “Add to Login Items” reliably works on macOS 13+ without warnings.
  - Status: Implemented minimal helper bundled at `Contents/Library/LoginItems/DockClickHelper.app`. Menu actions use `SMAppService.loginItem(identifier:)`. Build script embeds and ad-hoc signs helper and main app for local use. Note: For full reliability without prompts/warnings, proper Developer ID signing is required.

- [x] Minimization behavior option
  - Add preference to choose “Minimize all windows” vs “Hide app” fallback.
  - Acceptance: User-configurable behavior; predictable results for non-minimizable windows.
  - Status: Implemented Minimize Behavior submenu (Minimize All Windows | Hide App) with persistence (`MinimizeBehavior`) and migration from legacy key. Click handler branches on selection.

- [x] Timer cleanup and consolidation
  - Debounce dock updates; remove redundant timers; ensure timers invalidated.
  - Acceptance: No stray timers; low idle CPU.
  - Status: Debounce via selector-based `Timer`; exponential backoff timer managed and invalidated on stop.

- [x] Error handling for AppleScript/AX
  - Clear error messages with codes and recovery hints; backoff/retry if Dock not accessible.
  - Acceptance: Useful logs; no silent failures.
  - Status: AppleScript path clears items on error and retries with exponential backoff up to 8 seconds; AX path guarded with trust checks. Errors surfaced in logs.

- [x] Notifications fallback/UX
  - Gracefully handle denied permissions and add a menu item “Enable Notifications…”.
  - Acceptance: No confusing silent failures; user guided to settings.
  - Status: Implemented “Enable Notifications…” flow; opens System Settings when denied and shows a message.

## Nice to have

- [x] Use `os_log` for structured logging
  - Replace `print` with unified logging, categories, levels.
  - Status: Added `Log` wrapper around os.Logger with categories (app, dock, events, accessibility, login, notifications, ui). Migrated key prints; remaining deep debug in minimizeApp can be migrated later.

- [ ] Unit tests for pure logic
  - Test coordinate conversions and hit-testing helpers.
  - Acceptance: CI/lint step passes tests locally (XCTest for logic-only).

- [x] Open System Settings shortcuts
  - Menu items to open Accessibility and Notifications panes.
  - [x] Done

- [ ] Build reproducibility
  - Optional swiftc flags (`-Osize` for release build) and version stamping in Info.plist.

## Documentation

- [ ] Update README with:
  - Permissions required and why
  - Known limitations (multi-display/dock position until fixed)
  - Start-at-login note about helper target
  - Build instructions with new script flags
