# Diptych 1.6.0

Run your scripts and command-line tools from Diptych: with arguments,
environment variables and templates, each run kept, timed, and readable by
your AI agent. The agent terminal behaves more like a real one, and a file
path typed into the path bar opens the file.

---

## Run ▸ for scripts and command-line tools

Apps have always had **Run App**. Now any program you may run that is not an
app — a shell script, a Python script, a compiled tool — has **Run ▸** in its
right-click menu.

- **Run with Arguments…** (⌥↩, also in the File menu) asks for the arguments
  on one line. It starts with the most recent ones; ↑ and ↓ step through the
  earlier ones, as at a prompt. The exact command, and the folder it runs in,
  are shown before anything runs.
- **Environment variables** for the program: name and value pairs under the
  arguments, added and removed as you like. They are set after your shell's
  start-up files, so your profile cannot override them, and they appear in
  the command shown: `CONFIG=Release ./build.sh dmg`.
- **Under it, what it was run with before**, most recent first. Choose one to
  run it again at once. **Ⓔ** marks the ones that set variables — two can read
  the same and differ only in those — and ⌥-click deletes one.
- **Templates.** Tick *Save as a template*, and that set of arguments and
  variables stays in the menu, marked **Ⓣ**. Choosing it opens the window
  filled in, instead of running at once. Templates are never rolled off.
- **It runs in the active pane's folder** — usually the program's own. When the
  other pane is active, the menu says so: *Run with Arguments… in "that
  folder"*.
- **The arguments go to your login shell as typed**, so quotes, `~`,
  `$VARIABLES` and wildcards work as at a prompt.
- **A downloaded program** is asked about before it runs. macOS checks
  downloaded apps; no one checks downloaded scripts.

---

## The Runs window

Every run is a tab of one **Runs** window, whichever window started it.

- **A real terminal**, so colours, progress bars, and questions the program
  asks all work. You can type to the program while it runs; once it ends, the
  tab takes no input.
- **How it ended, and how long it took**, as `time` reports it: *Finished*,
  *Failed — exit 2* or *Stopped*, with `real`, `user` and `sys` — the last two
  including everything the program started.
- **Copy Output**, **Stop**, **Run Again**, and a × on every tab. Closing a tab
  or the window while something runs asks first.
- **Many tabs:** they share the width, and when there are too many, ‹ › step
  through them and ⌄ lists them all. The tab in front is always in view.

---

## Each run is kept

Every run's record, and everything it printed, is kept in `~/.diptych/runs`,
private to you — also after its tab is closed and after Diptych quits.
**Settings ▸ Behaviour ▸ Keep runs and their output for** decides how long:
an hour to 30 days, or until deleted. A day by default. *Delete All Kept Runs*
clears them at once.

---

## Ask your agent why it failed

Three new MCP tools let the agent in the terminal read your runs, so "why did
the build fail?" needs no copying and pasting:

- **`list_runs`** lists them counted back from the latest: 1 is the last run,
  2 the one before. It says which tab is in front, how each ended and how long
  it took, and whether it was started by the Diptych running now or before a
  restart.
- **`get_run_output`** reads what a run printed — its last 400 lines by
  default, where an error usually is.
- **`get_diptych_info`** describes the running Diptych: its process, version,
  and how many runs this session started.

Agents can read runs; starting one is deliberately not offered. The agent's
`AGENTS.md` explains what a "run" is, and what "this run", "the last run" and
"since I restarted" mean.

---

## Each program's history is a file you can edit

A program's argument history is one small JSON file in
`~/.diptych/run-history`, with the program's path inside, so `grep` finds it.
*Run with Arguments… ▸ Edit History File…* opens it in Diptych's Text Edit.

- It spells out `"limit"`, `"unlimited"` and `"fixed"`. The limit starts as the
  one in Settings and is the program's own from then on.
- `"fixed": true` keeps a list exactly as you wrote it, for the order your
  fingers have learned.
- **The history follows the program.** Moved, it takes its history along.
  Copied, the copy inherits it once and then goes its own way.

---

## The agent terminal

- **Your keyboard layout works.** Option types what your layout puts on it —
  `#`, `@`, `\` and the rest — as in Terminal.app. *Use Option as Meta key* in
  Settings ▸ Appearance switches back to the shell's Meta for those who want
  it.
- **⌘⌫ deletes back to the start of the line**, and ⌘← and ⌘→ go to its start
  and end, as in Ghostty and iTerm.
- **Selecting is copying.** Let go of the mouse on a selection, and the text is
  on the clipboard and the selection cleared. ⌘C does nothing in a terminal, so
  a ⌘C pressed from habit cannot replace what you copied. A program that
  handles the mouse itself, as Claude does, keeps its own selection and its
  own copying.
- **One click is enough.** Clicking from a pane into the terminal gives it the
  keyboard at once; the cursor no longer stayed hollow until a second click.

---

## The path bar opens files

Type or paste a file's path into the path bar and press Return: Diptych goes
to its folder, selects it and opens it, as Return on its row would. Tab
completes file names as well as folders, and a path to a file is no longer
shown in red.

---

## Also

- **About Diptych** now says what Diptych is: *Diptych — pronounced 'deep
  tech' — a two-pane AI driven file manager for macOS.*
- **The icon map in a `.DS_Store` preview stays readable.** It used to shrink
  everything to fit, so a folder of many icons became specks with unreadable
  names. Now only the spacing shrinks, never below half; the dots and names
  keep their size, long names are shortened (the whole name shows on hover),
  and a large map scrolls in its box.
- **Choosing the Git program is no longer a one-way street.** Settings ▸
  Version Tracking now offers *Find it automatically* or *Use a program I
  choose*, right under the Git that was found, with *Choose Another…*. And a
  chosen program now stays as chosen: picking Homebrew's `/opt/homebrew/bin/git`
  stored the versioned folder it links to, which `brew upgrade` deletes —
  silently switching version tracking off. If yours was chosen that way, it
  shows in red; choose it again, or switch to automatic.
- **Signed with the new Developer ID certificate.** Apple's original
  Developer ID authority expires on 1 February 2027; this release is signed
  with its G2 replacement. Earlier releases keep working.

---

## Upgrading

Nothing to do. Nothing new runs until you choose Run ▸, and the Runs window
appears only then.

---

*803 tests.*
