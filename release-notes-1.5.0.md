# Diptych 1.5.0

An agent terminal inside the window, with your AI agent already running and
already connected to Diptych. Agents can now propose extended-attribute and
Finder-tag changes, including removing quarantine. Other apps' "Show in
Finder" can open Diptych instead. And a long-standing bug in how Diptych
routed mouse clicks is fixed.

---

## The agent terminal

A thin strip now runs along the bottom of every window. Click it, press ⌃`,
or choose **View ▸ Show Agent Terminal**, and a terminal opens under the
panes and the sidebar, with your agent already running in it: Claude Code by
default, or Codex, Copilot, or anything else you name in **Settings ▸
Agents**. It is there to talk to an agent about the files you are looking at,
in plain language, without setting anything up.

- **It starts in `~/.diptych/agentic`**, not in your files. The agent reaches
  files through Diptych, so where it stands does not matter. You can choose
  another folder in Settings ▸ Agents.
- **Diptych prepares that folder every time.** It switches agent access on
  and writes three files:
  - `.mcp.json`, with the current port and token;
  - `AGENTS.md`, the agent's instructions;
  - `CLAUDE.md`, which imports them, because Claude Code reads only that file.
- **The instructions are mostly one rule: change files only through Diptych.**
  Every change is a proposal you review in a window before anything happens,
  never a shell command. The agent may read files, and may keep scratch files
  in `$TMPDIR`. "This" means what you have selected, and "the other side"
  means the other pane. Delete the first line of either instruction file and
  Diptych leaves that file alone from then on.
- **The agent runs in your login shell,** so your `PATH` and start-up files
  apply, once. When the agent exits, the shell stays.
- **Clicking the strip** folds the terminal back down with everything still
  running, and opens it again. Drag the strip to resize it. The height is
  remembered.
- **Drop files on it** from a pane or from Finder, and their paths are typed
  in, quoted for the shell.
- **It has its own look:** font, size, and colours that follow the system,
  stay light or dark, or are your own choice, in **Settings ▸ Appearance ▸
  Agent Terminal**.
- **While it has the keyboard, Diptych's own keys stand aside.** Tab
  completes, Return runs, and ⌘C and ⌘V copy and paste text.
- **Closing a window asks first** when its terminal is running something
  other than a shell prompt, by name: "Close this window and end
  “claude”?" Quitting Diptych ends every agent terminal.

Agent access has moved into its own **Settings ▸ Agents** tab, together with
the agent command and folder.

---

## Extended attributes and Finder tags, proposed and reviewed

An agent's batch of file operations can now also:

- **set or remove an extended attribute.** Removing `com.apple.quarantine`
  is how a download's "are you sure you want to open it?" check is cleared.
  Values can be given as text, hex or base64.
- **add, remove or set Finder tags.** Tags are added to, or removed from,
  what the item has *when the batch runs*, and Finder's label colour is kept
  in step.

In the review window, every such row shows what the item has now next to what
it will have. Attribute values appear as text, as a property list or as hex;
tags appear as coloured chips. The row's own tags can be removed with their ×,
and new ones added from a field. Well-known attributes say what they are.
A row that would change nothing says **No change**.

**Read-only items are settled with one question for the whole batch.** You can
unlock the ones you own for the moment the change takes and restore their
permissions straight afterwards, authenticate once as an administrator for
all of them, or skip them. Undo puts back the exact bytes each attribute held
before.

---

## Attribute changes are checked

macOS accepts some attribute changes and quietly ignores them. Diptych used to
take that acceptance at its word. Removing `com.apple.provenance` was reported
as done, in the Info window and in a batch, while the attribute stayed exactly
where it was.

Every attribute change is now read back afterwards. A change that did not
happen is reported as failed, with the reason. Attributes macOS keeps for
itself are flagged before anything is tried: a batch row proposing to remove
one shows the problem, and the Info window's **Remove** button is off for them.

---

## Where a file came from: com.apple.provenance

macOS stamps `com.apple.provenance` on files made or changed by an app it
tracks. Where this used to be a row of hex, Diptych now shows its provenance
ID and the installed apps that carry the same tag.

In **Get Info ▸ Attributes**, **Identify App…** names the app exactly: its
path, bundle ID, team, and since when macOS has tracked it. That comes from
macOS's own provenance database, which only an administrator can read, so it
asks for your password once and opens the database read-only. The answer is
kept in `~/.diptych/provenance.sqlite`, so each ID is looked up only once, and
it then labels every file with that ID in every window.

---

## Diptych instead of Finder

**Settings ▸ Behaviour ▸ Show files in Diptych instead of Finder** makes other
apps' **Show in Finder** and **Reveal in Finder** open the folder in Diptych,
with the file selected. It uses the same macOS setting as ForkLift and Path
Finder, and the README gives the two `defaults` commands behind it.

- **Apps that are already open** keep using Finder until you reopen them.
- **Unaffected:** apps that address Finder directly by name, and Finder's own
  features.
- **If the macOS setting is lost,** Diptych puts it back at launch while the
  switch is on.
- **Switching it off** leaves alone another app you may have chosen since.

---

## Clicks went to the wrong place

Diptych looks at every mouse click to decide which pane it belongs to, and it
had been working that out mirrored top to bottom. While the panes filled the
window, the mistake mostly did not show. With the terminal under them, it did:
a click in the terminal could select a pane, and a click on a pane could leave
the keyboard in the terminal. Both are fixed.

It also fixes an old bug: **right-clicking the empty space below a short
listing** now brings up the New File, New Folder and Paste menu, as it always
should have.

---

## Upgrading

Nothing to do. The agent terminal starts only when you open it. Agent access
is still off until you open the terminal or switch it on yourself. Showing
files in Diptych instead of Finder is off until you tick it.

---

*780 tests.*
