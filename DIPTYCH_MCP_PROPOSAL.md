---
checksum: 4fcf2b5500b0785e84dba2b883615ec2cf9ef6df50d6c687e744f6572a904d28
checksum_algorithm: sha256
number:
  style: period
  skip-title: true
---
# Diptych MCP Proposal
<!--TOC
min-level: 2
max-level: 3
_content_generated_: 904:md5:1ca48d25d55b29e0dc2fd602ad3d681b
# ⚠️ MANAGED CONTENT: Edits will be lost.
# danger zone: Delete _content_generated_ to override.
-->
- [Context](#context)
- [Part 1 — Sensible usages (scenarios)](#part-1-sensible-usages-scenarios)
- [Part 2 — Supporting data-oriented resources](#part-2-supporting-data-oriented-resources)
- [Part 3 — Round-trip tools (optional/secondary)](#part-3-round-trip-tools-optionalsecondary)
- [Part 4 — Supporting app features required to make this usable](#part-4-supporting-app-features-required-to-make-this-usable)
- [Part 5 — Batch file operations with human confirmation](#part-5-batch-file-operations-with-human-confirmation)
  - [Tool: `propose_file_operations(operations)`](#tool-propose-file-operationsoperations)
  - [Review window behavior](#review-window-behavior)
  - [Reporting results back to the agent](#reporting-results-back-to-the-agent)
- [Explicitly out of scope](#explicitly-out-of-scope)
- [Architecture note (flagged, not designed here)](#architecture-note-flagged-not-designed-here)
<!--/TOC-->
## Context

Diptych is a native macOS dual-pane file manager (Swift/SwiftUI). It currently has no MCP code, no CLI entry point, and no library surface — everything is UI-driven.

The obvious first idea — wrap diptych's file-operation and diffing functions (copy/move/trash/rename, text/binary/directory diff, git status, report export) as MCP tools — turns out to add little value: all of that is already trivially available to an LLM via bash/shell on macOS.

The actual value is different: diptych is a **long-running GUI app with live, stateful, in-memory session data** that bash cannot see — which files are selected in the active pane right now, what directory-diff or text-diff window is open and what it shows, what path a pane is browsing. While diptych runs, it can expose an MCP server on a local port. The user works the GUI as normal (clicking, selecting, opening a diff view) and, separately in a terminal, asks an agent questions about what's currently on screen. This **extends** diptych rather than duplicating what's already scriptable from the shell.

There's a second category of value beyond live-state introspection: batched, human-reviewed *mutations*. Bash can execute file operations, but it can't pause a multi-step batch for the user to visually review, edit, and approve before anything happens — diptych's GUI can. See Part 5.

## Part 1 — Sensible usages (scenarios)

What a user, mid-session in the GUI, would plausibly type into an agent in another terminal window:

**A. About the current selection (active pane)**
- "Which is the largest of the selected files?"
- "Total size of what I've selected — does it fit on a 4GB USB stick?"
- "Any of my selected files modified in the last hour?"
- "Are any of these selected files duplicates of each other by content?"
- "Give me a one-line description of each selected file, for a changelog."

**B. About an open directory-diff window**
- "What two folders is this diff window comparing, and with what filter/exclude options?"
- "Were any files renamed rather than added+removed?" (diptych's rename detection doesn't reduce to a plain bash diff)

**C. About an open text-diff / edit session**
- "What two files does this diff session cover?"
- "Is this diff saved, or do I have unsaved edits?"

**D. Orientation — "what's diptych doing right now"**
- "What windows/tabs do I currently have open?"
- "What directory is each pane currently browsing?"
- "Do I have any diff sessions with unsaved changes I should deal with?"

**E. Git context, scoped to what's on screen**
- "Which repo (and path within it) is the pane I'm looking at actually browsing?"

(Deliberately *not* a general-purpose git tool — that's bash-equivalent; the value is only in "the repo the user is currently looking at.")

**F. Round-trip — agent acts back into the GUI (optional/secondary)**
- "Select the 5 largest files [in my current selection/pane]." → agent computes and calls back into the pane's selection, so the answer is visibly reflected in the GUI, not just printed in the terminal.
- "Jump the left pane to ~/Downloads."
- "Open a diff between these two folders." (agent-initiated compare, user reviews visually)
- "Show me the Info window for this file."
- "Rename these by lowercasing everything and replacing spaces with underscores — preview it before you apply it." (agent turns the instruction into a bulk-rename plan the user reviews visually in diptych before committing)

**G. Batch operations, reviewed before execution**
- "Move all the orange-tagged files into /Archive, but let me check before anything happens."
- "Delete the files matching `*.tmp` older than 30 days — show me the list first."
- "Rename these 40 files by stripping the date prefix, set them all to read-only, and let me approve."

This is the "please… orange… oh, good, I see you wanted that one too — let's exclude it before deleting" workflow: the agent collects operations instead of executing them one at a time, diptych shows the full list for review, and nothing happens until the user approves. See Part 5.

## Part 2 — Supporting data-oriented resources

Each scenario above needs one of these; resources should stay **data-shaped, not question-shaped** — e.g. no bespoke "largest file" endpoint, just structured metadata the agent reasons over. None of these deliver diff/comparison *content* — that part is bash-reproducible once the agent knows what's being compared, so each resource below is scoped to context (paths, options, live-only state) instead.

| Resource                              | Backing state                                                        | Feeds scenarios              |
| ------------------------------------- | -------------------------------------------------------------------- | ---------------------------- |
| `list_windows()`                      | `AppState.swift`                                                     | D                            |
| `get_pane(paneId)`                    | `PaneModel`/`PaneState`                                              | D, F                         |
| `get_selection(paneId="active")`      | `PaneState.selection` + `FileItem` metadata                          | A, F                         |
| `get_active_directory_diff_context()` | `DirectoryDiffModel` — paths + active filter/exclude options only    | B                            |
| `get_directory_diff_renames()`        | `DirectoryComparison` rename-detection results                       | B                            |
| `get_active_text_diff_context()`      | `DiffDocument` — file paths + saved/unsaved state (not diff content) | C                            |
| `get_active_binary_diff_context()`    | `BinaryComparison` — file paths only (not diff content)              | (byte-diff scenarios, minor) |
| `get_active_repo_context()`           | active pane's repo root path (not git status)                        | E                            |

## Part 3 — Round-trip tools (optional/secondary)

| Tool                                     | Backing state                                                                                                                                      | Scenario |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `select_items(paneId, paths)`            | `PaneState.selection`                                                                                                                              | F        |
| `navigate_pane(paneId, path)`            | `PaneModel`                                                                                                                                        | F        |
| `open_diff(left, right)`                 | `AppModel.showDiff`                                                                                                                                | F        |
| `open_info_window(paneId, path)`         | `AppModel` (Info window)                                                                                                                           | F        |
| `plan_bulk_rename(paneId, instructions)` | `RenameManyModel`/`RenamePlan` — turns a natural-language instruction into a regex-based rename plan for visual preview before the user applies it | F        |

## Part 4 — Supporting app features required to make this usable

The MCP surface alone isn't usable without related changes elsewhere in the app.

1. **Settings: enable/disable the local MCP server**, off by default (consistent with the Git-integration precedent of opt-in), with configurable bind address, port, and access scope — the simplest case being localhost-only, so nothing off-machine can reach it. Status is shown via a small LED-style indicator next to an "MCP" label in the window chrome: off when disabled, steady when listening idle, flashing in different colors while a request is being handled, and red when a connection attempt is refused — because unlike anything else in the app today, this opens a local network listener, so it needs to be legible/trustable to the user at a glance.

2. **Menu action: create/edit `.mcp.json`** — adds or merges a diptych entry into `.mcp.json` in a chosen directory (default: the active pane's current directory), so agent CLIs (Claude Code, Codex, etc.) auto-discover diptych's endpoint there. Must **merge**, not overwrite, since a directory may already have other MCP servers configured — needs the same care the app already applies to conflict-safe writes elsewhere (e.g. git conflict handling).

3. **Single-instance enforcement** — diptych currently has no mechanism preventing multiple simultaneous instances (a regular macOS app can still be launched more than once via `open -n` or running the binary directly). With implicit session binding (below), exactly one diptych process/MCP server binding, so it needs a startup check that detects an already-running instance. Rather than silently refusing to launch, the second instance should let the user choose: stop the prior instance and continue starting the new one, or quit the just-started second instance and activate/front the existing one. No current precedent for this in the codebase.

4. **Menu action: "Open Agent Terminal Here"** — opens a terminal in the relevant directory and starts the user's configured agent command, with **implicit session binding**: the launched terminal is bound (e.g. via an env var/session token) to the diptych window it was opened from, so unscoped queries ("largest of the selected files") default to that window's context without the user naming an id. Three implementation approaches:

   - **A. Independent external terminal app** (lowest effort — the MVP choice): shell out to Terminal.app, macOS's standard terminal (guaranteed present on every installation), and start it in the relevant directory. No positional relationship to diptych's window. Pros: smallest change, reuses the existing "run an external command" pattern already in `ScriptCatalogue`, works with zero configuration. Cons: a floating, unrelated window the user has to place themselves; the user's preferred terminal (iTerm, Ghostty) isn't used unless a later revision makes the terminal app configurable.

   - **B. Position-synced external terminal app** (low–moderate effort, deferred): same idea as A, but the window is docked/tracked via AppleScript/Apple Events (`tell application "Terminal" to set bounds of window …`), driven by diptych's own `NSWindow` move/resize delegate callbacks, so the terminal snaps to an edge of the diptych window and stays in lockstep — visually "attached" without true embedding. Requires the user to grant macOS **Automation** permission (one-time consent prompt to let diptych control the chosen terminal app) — a much lighter ask than Accessibility permission, and works regardless of diptych's sandbox status.

     True cross-process view embedding (one seamless frame, one title bar) is **not possible via public macOS APIs** — a process cannot reparent another process's window into its own view hierarchy. The private/undocumented SkyLight APIs some tiling-window-manager tools use for this are not worth building on (unsupported, break across OS updates). So even with this approach it remains two OS windows under the hood: two title bars, independently draggable by the terminal's own chrome, listed separately in Mission Control/Cmd+Tab.

   - **C. Embedded terminal pane via SwiftTerm** (deferred): a real terminal view inside diptych's own window, built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (an existing, actively-maintained MIT-licensed Swift package providing PTY handling + VT100/xterm rendering as a native AppKit/SwiftUI view) rather than a homegrown emulator. Pros: genuine single-window integration, one title bar, no second app to manage. Cons: a new third-party dependency and a new view/subsystem in the codebase — moderate effort, though far less than writing a terminal emulator from scratch.

5. **Configurable agent launch command** — which command starts the agent (`claude`, `codex`, or a custom command/args). For MVP, the terminal app itself is fixed to Terminal.app (per Option A); making the terminal app choice configurable (iTerm, Ghostty) is a later enhancement, not required for MVP. Reuse the existing user-approved-command settings pattern (`ScriptCatalogue`/`ScriptDefinition`) rather than inventing a new config surface.

6. **Local auth for the MCP port** — even bound to localhost, a listening port is new attack surface for this app; needs a token/pairing mechanism (e.g. a token embedded in the `.mcp.json` entry written in item 2) so only intentionally-configured clients can query it.

## Part 5 — Batch file operations with human confirmation

Unlike the individually-executed shell equivalents, the value here isn't the operations themselves — it's that nothing happens until the user has seen the whole list and approved it. This is what makes "please move the orange files" safe to ask in one sentence: the agent proposes, diptych shows exactly what it understood, and the user catches the one file that shouldn't be included *before* it's touched, not after.

### Tool: `propose_file_operations(operations)`

Takes a list of individual file operations and returns a `batchId`; diptych opens a review window listing all of them and does not execute anything until the user approves.

| Field    | Description                                                                                                                                                                       |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `op`     | One of: `copy`, `move`, `rename`, `delete` (to Trash), `delete_permanent`, `set_owner`, `set_group`, `set_permissions`, `set_extended_attribute`, `create_symlink`                |
| `source` | Path(s) the operation applies to                                                                                                                                                  |
| `target` | Destination path, new name, new owner/group, permission bits, symlink target, or attribute key/value — depending on `op`                                                          |
| `reason` | Short agent-supplied rationale shown next to the item in the review list (e.g. "tagged orange"), so the user sees *why* each item was included, not just *what* will happen to it |

Backing code: `Model/FileOperations.swift` already implements each of these operations atomically; `Model/RenameManyModel.swift`/`RenamePlan.swift` already implements exactly this plan-then-apply shape (including dependency-ordering and cycle detection for chained renames) for one operation type — this generalizes that existing pattern to a heterogeneous batch of operation types rather than introducing a new one. `set_extended_attribute` would be new: it has no current write path in `FileOperations`, though the Info window's existing Attributes tab already reads this data.

### Review window behavior

- Every operation is listed with its old state → new state (or, for delete, what will be removed and whether it's reversible via Trash), grouped and sortable.
- Conflicts are pre-flight-checked and highlighted before the user has to notice them manually: destination already exists, permission would be denied, source has vanished since the batch was proposed, a rename cycle, etc.
- Every item has a per-item exclude checkbox, checked (included) by default — the "oh, exclude that one" gesture from the motivating scenario. Excluding an item removes only that item; the rest of the batch is unaffected.
- Irreversible operations (`delete_permanent`, and any operation that would silently overwrite an existing file) require a second, explicit acknowledgement beyond the general "Execute" action for the batch — mirroring the trash-vs-delete distinction diptych's own file operations already make.
- On approval, diptych executes the batch in dependency order (reusing `RenamePlan`'s existing ordering/cycle-handling logic, generalized across operation types — e.g. a directory created earlier in the same batch that a later `move` targets) and registers the whole approved batch as a single undo group, so one undo reverts everything that was actually executed. Extending the existing per-verb undo system to group a heterogeneous batch this way is new work, not something it does today.
- The Part 4.1 status LED gets a distinct color/state for "batch awaiting your review," so the user notices even when diptych isn't the focused window.

### Reporting results back to the agent

`propose_file_operations` returns the `batchId` immediately and does not block — most MCP clients time out on long-blocking calls, and review can take arbitrarily long. A second tool, `get_batch_status(batchId)`, lets the agent (or the user, via a follow-up question) see what happened: still pending review, rejected outright, approved with specific items excluded, or finished executing with a per-item success/failure/skipped result. This polling shape is the simplest fit for MCP's request/response model; a server-initiated push notification would let the agent report back proactively instead of the user having to ask "did you approve it yet?" — worth revisiting once that's reliably supported, not designed further here.

## Explicitly out of scope

- Individual, silently-executed filesystem ops that just re-implement what's already reachable via bash (copy/move/trash/rename/permissions/generic git status-of-a-named-path) — no added value over shell access. The exception is Part 5's batched, human-reviewed operations: the value there isn't the operation itself, it's the GUI confirmation step bash has no equivalent for.
- Raw/low-level git passthrough — consistent with the app's own git-integration design philosophy.
- Server-side natural-language interpretation — MCP exposes structured state; the agent does the reasoning.
- Options B and C for the agent terminal (Part 4.4) — deferred; MVP uses Option A with Terminal.app fixed (non-configurable). Making the terminal app configurable (iTerm, Ghostty) is left for a later revision.

## Architecture note (flagged, not designed here)

Reaching a *specific running instance's* in-memory state (not stateless disk data) means diptych itself must host a local MCP server for as long as it's running, backed directly by `AppModel`/`PaneModel`/`DirectoryDiffModel` on the main actor — a real design task (transport, threading against `@MainActor` state, multi-window addressing, port lifecycle) intentionally left for a dedicated follow-up plan.
