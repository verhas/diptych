# Diptych MCP Proposal

## Context

Diptych is a native macOS dual-pane file manager (Swift/SwiftUI). It currently has no MCP code, no CLI entry point, and no library surface — everything is UI-driven.

The obvious first idea — wrap diptych's file-operation and diffing functions (copy/move/trash/rename, text/binary/directory diff, git status, report export) as MCP tools — turns out to add little value: all of that is already trivially available to an LLM via bash/shell on macOS.

The actual value is different: diptych is a **long-running GUI app with live, stateful, in-memory session data** that bash cannot see — which files are selected in the active pane right now, what directory-diff or text-diff window is open and what it shows, what path a pane is browsing. While diptych runs, it can expose an MCP server on a local port. The user works the GUI as normal (clicking, selecting, opening a diff view) and, separately in a terminal, asks an agent questions about what's currently on screen. This **extends** diptych rather than duplicating what's already scriptable from the shell.

## Part 1 — Sensible usages (scenarios)

What a user, mid-session in the GUI, would plausibly type into an agent in another terminal window:

**A. About the current selection (active pane)**
- "Which is the largest of the selected files?"
- "Total size of what I've selected — does it fit on a 4GB USB stick?"
- "Any of my selected files modified in the last hour?"
- "Are any of these selected files duplicates of each other by content?"
- "Give me a one-line description of each selected file, for a changelog."

**B. About an open directory-diff window**

//AI: Per the Context section's own principle (line 7) and the note further down about text/binary diffs, most of these questions (summarize differences, files >1MB, source-vs-build-artifact classification) are answerable via bash `diff -rq`/`find`/`stat` once the two directory paths are known — the paths plus any active filter/exclude options set in the diff window are the genuinely new information here. The clear exception is "were any files renamed" — diptych's `DirectoryComparison` does attribute-based rename detection that plain `diff`/`rsync` doesn't provide, so that one is a real value-add. Consider narrowing this list to "what am I comparing and with what options" plus the rename-detection case.

- "Summarize what's different between these two folders in plain English."
- "Which changed files are only different in permissions/ownership, not content?"
- "Of the changed files, which are source code vs. build artifacts I can ignore?"
- "Were any files renamed rather than added+removed?"
- "Which changed files are larger than 1MB?"

**C. About an open text-diff / edit session**

//AI: Three of these four (lines added/removed, conflict markers, which side has more changes) are answerable via bash `diff` once the two file paths are known — same issue as directory diff above. "Is this diff saved, or do I have unsaved edits?" is different: unsaved edits live only in the running `DiffDocument`'s in-memory/undo state with no bash equivalent, so that's the genuinely valuable question in this list.

- "How many lines were added vs. removed overall?"
- "Does this diff still have unresolved conflict markers?"
- "Is this diff saved, or do I have unsaved edits?"
- "Which side (left/right) has more changes?"

**D. Orientation — "what's diptych doing right now"**
- "What windows/tabs do I currently have open?"
- "What directory is each pane currently browsing?"
- "Do I have any diff sessions with unsaved changes I should deal with?"

**E. Git context, scoped to what's on screen**

//AI: These two example questions ask for the output of `git status`/`git status -sb` (ahead/behind, tracked/untracked) — exactly what the parenthetical note right below concedes is bash-equivalent once the repo path is known. The examples contradict the principle they're meant to illustrate. Replace with a question bash genuinely can't answer, e.g. "which repo/path is the pane I'm looking at actually browsing?"

- "Is the folder I'm currently in ahead or behind origin?"
- "What's tracked vs. untracked in my current pane's repo?"

(Deliberately *not* a general-purpose git tool — that's bash-equivalent; the value is only in "the repo the user is currently looking at.")

**F. Round-trip — agent acts back into the GUI (optional/secondary)**
- "Select the 5 largest files [in my current selection/pane]." → agent computes and calls back into the pane's selection, so the answer is visibly reflected in the GUI, not just printed in the terminal.
- "Jump the left pane to ~/Downloads."
- "Open a diff between these two folders." (agent-initiated compare, user reviews visually)

## Part 2 — Supporting data-oriented resources

Each scenario above needs one of these; resources should stay **data-shaped, not question-shaped** — e.g. no bespoke "largest file" endpoint, just structured metadata the agent reasons over.

//AI: This table is split into three fragments below by blank lines and the inline `//AI:` notes (around `get_active_directory_diff`, then `get_active_text_diff`/`get_active_binary_diff`, then `get_active_git_context`). In GFM, only the first fragment has a header + delimiter row, so the rows after each break won't render as table rows — they'll show as literal pipe-delimited text. Move these inline comments above or below the table (or gather them in one place) when applying fixes, so the table stays one contiguous block.

| Resource | Backing state | Feeds scenarios |
|---|---|---|
| `list_windows()` | `AppState.swift` | D |
| `get_pane(paneId)` | `PaneModel`/`PaneState` | D, F |
| `get_selection(paneId="active")` | `PaneState.selection` + `FileItem` metadata | A, F |
| `get_active_directory_diff()` | `DirectoryDiffModel` | B |

//AI: Same issue as the note below for text/binary diff — as described, this returns full comparison results (`DirectoryDiffModel`), which is bash-reproducible via `diff -rq`/`find`/`stat` once the two paths and active filter/exclude options are known, except for diptych's rename-detection heuristic. Narrow the "backing state" to comparison context (paths + options), with rename info called out separately.

//AI: text and binary diff is available via bash diff command
//AI: mcp may need to tell what is compared in the active diff window, does not need to deliver the diff content

| `get_active_text_diff()` | `DiffDocument` | C |
| `get_active_binary_diff()` | `BinaryComparison` result | (byte-diff scenarios, minor) |

//AI: git is available (or not) as a bash command, the MCP must not implement anything that is awailable in a simpler way to the agent via bash

| `get_active_git_context()` | `GitService.status` for active pane's repo | E |

## Part 3 — Round-trip tools (optional/secondary)

| Tool | Backing state | Scenario |
|---|---|---|
| `select_items(paneId, paths)` | `PaneState.selection` | F |
| `navigate_pane(paneId, path)` | `PaneModel` | F |
| `open_diff(left, right)` | `AppModel.showDiff` | F |

//AI: open information window on a file
//AI: open multiple rename so that the user expresses in English what she wants to rename and how, and then use diptych to have a visual preview what is happening, before pressing "rename"

## Part 4 — Supporting app features required to make this usable

The MCP surface alone isn't usable without related changes elsewhere in the app.

1. **Settings: enable/disable the local MCP server**, off by default (consistent with the Git-integration precedent of opt-in), with a configurable port and a visible running-status indicator (port, active/inactive) — because unlike anything else in the app today, this opens a local network listener, so it needs to be legible/trustable to the user.

//AI: It has to be an LED light on the top of the window, with MCP close to it and flashing in different colors when actual use happens. Red when a connection is refused
//AI: the binding address as well as the port is to be configured and also what can access it. Simplest case localhost accessible only from localhost.

2. **Menu action: create/edit `.mcp.json`** — adds or merges a diptych entry into `.mcp.json` in a chosen directory (default: the active pane's current directory), so agent CLIs (Claude Code, Codex, etc.) auto-discover diptych's endpoint there. Must **merge**, not overwrite, since a directory may already have other MCP servers configured — needs the same care the app already applies to conflict-safe writes elsewhere (e.g. git conflict handling).

3. **Single-instance enforcement** — diptych currently has no mechanism preventing multiple simultaneous instances (a regular macOS app can still be launched more than once via `open -n` or running the binary directly). With implicit session binding (below), there must be exactly one diptych process/MCP server to bind to, so this needs a startup check that detects an already-running instance and activates/fronts it instead of launching a second one. No current precedent for this in the codebase.

//AI: when a second instance is started the user must be able to decide to stop the prior instance and start the new one or just quit the second instance just started.

4. **Menu action: "Open Agent Terminal Here"** — opens a terminal in the relevant directory and starts the user's configured agent command, with **implicit session binding**: the launched terminal is bound (e.g. via an env var/session token) to the diptych window it was opened from, so unscoped queries ("largest of the selected files") default to that window's context without the user naming an id. Three implementation approaches, decision deferred to a later dev phase:

   - **A. Independent external terminal app** (lowest effort): shell out to a *configurable* terminal app — the user has Terminal.app, iTerm, and Ghostty installed and wants to pick one rather than default to Terminal.app. No positional relationship to diptych's window. Pros: smallest change, reuses the existing "run an external command" pattern already in `ScriptCatalogue`. Cons: a floating, unrelated window the user has to place themselves.

   - **B. Position-synced external terminal app** (low–moderate effort): same external app as A, but its window is docked/tracked via AppleScript/Apple Events (`tell application "Terminal" to set bounds of window …`), driven by diptych's own `NSWindow` move/resize delegate callbacks, so the terminal snaps to an edge of the diptych window and stays in lockstep — visually "attached" without true embedding. Requires the user to grant macOS **Automation** permission (one-time consent prompt to let diptych control the chosen terminal app) — a much lighter ask than Accessibility permission, and works regardless of diptych's sandbox status.

     True cross-process view embedding (one seamless frame, one title bar) is **not possible via public macOS APIs** — a process cannot reparent another process's window into its own view hierarchy. The private/undocumented SkyLight APIs some tiling-window-manager tools use for this are not worth building on (unsupported, break across OS updates). So even with this approach it remains two OS windows under the hood: two title bars, independently draggable by the terminal's own chrome, listed separately in Mission Control/Cmd+Tab.

   - **C. Embedded terminal pane via SwiftTerm**: a real terminal view inside diptych's own window, built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (an existing, actively-maintained MIT-licensed Swift package providing PTY handling + VT100/xterm rendering as a native AppKit/SwiftUI view) rather than a homegrown emulator. Pros: genuine single-window integration, one title bar, no second app to manage. Cons: a new third-party dependency and a new view/subsystem in the codebase — moderate effort, though far less than writing a terminal emulator from scratch.

5. **Configurable agent launch command** — which command starts the agent (`claude`, `codex`, or a custom command/args), and which terminal app to use if approach A or B is chosen. Reuse the existing user-approved-command settings pattern (`ScriptCatalogue`/`ScriptDefinition`) rather than inventing a new config surface.

6. **Local auth for the MCP port** — even bound to localhost, a listening port is new attack surface for this app; needs a token/pairing mechanism (e.g. a token embedded in the `.mcp.json` entry written in item 2) so only intentionally-configured clients can query it.

## Explicitly out of scope

- Anything re-implementing filesystem ops already reachable via bash (copy/move/trash/rename/permissions/generic git status-of-a-named-path) — no added value over shell access.
- Raw/low-level git passthrough — consistent with the app's own git-integration design philosophy.
- Server-side natural-language interpretation — MCP exposes structured state; the agent does the reasoning.
- Deciding between the three terminal approaches (Part 4.4) — documented as options for a later decision, not decided here. 

//AI: This appears to conflict with Option A above (Part 4.4), which explicitly says the terminal app should be *configurable* "rather than default to Terminal.app." Clarify whether the MVP hardcodes Terminal.app specifically (dropping configurability for v1) or whether the launch command stays configurable and just happens to default to Terminal.app initially — as written a reader can't tell which is meant.

//AI: For MVP, the standard Terminal will be started independently.

## Architecture note (flagged, not designed here)

Reaching a *specific running instance's* in-memory state (not stateless disk data) means diptych itself must host a local MCP server for as long as it's running, backed directly by `AppModel`/`PaneModel`/`DirectoryDiffModel` on the main actor — a real design task (transport, threading against `@MainActor` state, multi-window addressing, port lifecycle) intentionally left for a dedicated follow-up plan.
