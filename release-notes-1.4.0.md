# Diptych 1.4.0

One large new feature: a local AI agent -- Claude Code, Codex, anything that
speaks MCP -- can now ask Diptych about what is on your screen, and act back
into it. Off until you switch it on.

---

## Why this, and not file operations

An agent in a terminal can already copy, move and list files; wrapping those
for it would add nothing. What it cannot see is Diptych itself: which files
are selected in the pane you are looking at, what folder each pane is
browsing, which comparison window is open and with what options, whether an
edit is unsaved. That is what this exposes. You click and select in Diptych
as usual, and in another window ask the agent "which of the selected files is
the largest?" or "what do these two folders differ in?" -- and it answers
about what is actually on screen.

---

## Switching it on

**File ▸ Add Diptych to Agent Config (.mcp.json)…** does everything in one
step: it switches the server on and adds an entry to `.mcp.json` in the active
pane's folder, which an agent started in that folder picks up by itself. The
file is merged, never overwritten -- anything else already configured there
stays. The switch on its own is in Settings ▸ Behaviour.

The server listens on `127.0.0.1` only, and every request needs a token. The
token is kept in `~/.diptych/.mcp.token`, readable by you alone, and not in
`config.json`, which is meant to be read and edited by hand. Settings shows
it, and **Regenerate** replaces it at once -- the old one stops working
immediately, not at the next restart.

---

## What an agent can do

Look: every open window and what it shows, a pane's folder and listing, the
selection, what a Compare or Compare Folders window is comparing -- including
the renames Diptych's own content matching found, which a plain `diff` cannot
tell you -- and a curated set of settings.

Act: select files in a pane, switch the active pane, open a comparison of two
paths or the Info window of one, close a window (with the same
unsaved-changes question ⌘W asks), and change a setting -- "is the update
check on? switch it off" works without knowing where it lives in Settings.

Nothing reads or writes file contents.

---

## Batches of file operations, reviewed first

The one kind of file operation an agent gets is a **proposal**. "Move the
archives to the other folder, read-only" turns into a window listing every
operation it understood, each one ticked, and nothing happens until you press
Execute. Untick the one file that should not be in there; change a
destination, a name, an owner, or the permissions in the same rwx grid the
panes use. A permission row shows what the item has now beside what it will
get, and says **No change** when those are the same.

The batch is checked as a whole before it can run -- two operations landing
on the same path, or depending on each other in a circle, are named and block
it. An operation that would overwrite something, or delete permanently, needs
a tick of its own, for that exact path. Owner changes that need an
administrator are done together after a single password prompt. More than ten
operations are confirmed once more. Afterwards every row says what happened,
failures in red, and what was done can be undone.

---

## Seeing what an agent does

While the server is on, a small dot in the toolbar pulses green on each
request and red on a rejected one. Clicking it opens **MCP Activity**: every
call, with its arguments, and every refused request.

---

## Only one Diptych at a time

Starting Diptych a second time now brings the running one forward instead of
opening another alongside it. An agent's question about "the selection" has to
mean one particular window's selection, and two copies of the app would make
that a guess.

---

## A smaller app, and a second file on the release page

Every Diptych so far shipped with its full table of internal function names
inside the app -- something only debugging ever reads. The libraries agent
access is built on have a great many very long such names, and kept in, they
would have made the app well over twice its size. From this release on, they
are removed from the app before it is packaged: the app is about the size
1.3.3 was, with all of the above added.

The names are not thrown away. Each release on GitHub now carries
`Diptych-<version>-debug-symbols.zip` next to the disk image -- the one thing
that turns a crash report from that exact build back into readable function
names. **You do not need it**: download the `.dmg` as before. It sits on the
release page alongside the two "Source code" archives GitHub always adds,
and is there for the day a crash report needs reading. Updating from inside
Diptych picks the disk image and ignores it.

---

## Upgrading

Nothing to do. Agent access starts switched off.

---

*751 tests.*
