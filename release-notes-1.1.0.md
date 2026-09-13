# Diptych 1.1.0

Forty-nine changes since 1.0.0. Four of them are new things the application
does; the rest make those work, or fix what went wrong on the way.

The four are **version tracking**, a **comparison window** that can edit,
**scripts** you can add yourself, and **previews that look inside** folders and
archives.

---

## Version tracking

Diptych can now show what Git knows about a folder and do the three things a
person who is not a developer actually needs: keep a file, send their work, and
get everyone else's. It is **off by default** and switched on in Settings.

It uses the `git` already on the Mac — Diptych installs none — and says which
one it found, with the option of naming a different one. It checks the program
is called `git` and that it answers `git version`, and says plainly that this is
not a security check: a harmful program can be called `git` too.

### The colours

The name of a file is coloured by what Diptych knows about it:

| Colour | Meaning |
| --- | --- |
| brown | new — **will not be sent** unless you say so |
| green | new and tracked — will be sent |
| blue | tracked and changed — will be sent |
| purple | out of date: someone else has sent a newer version |
| red | cannot go as it stands: it clashes, or a merge was left half-finished |
| dimmed | a `(my version)` copy Diptych kept for you |
| *none* | nothing to send: unchanged, or ignored |

A folder takes the strongest colour of anything inside it, and the Git column
lists **every** state in there — `clash, out of date, changed, new` — because
one word can only report the worst thing and says nothing about the rest.

Purple and red are the two that depend on asking the server, so they appear only
after **Check for Changes** (⇧⌘K, or the toolbar button), the age of the answer
is always on screen beside the counts, and after thirty minutes the answer is
discarded and the colour goes with it. A claim about a server with no date on it
is a claim Diptych cannot back up.

### The three verbs

**Track this file** / **Never track this** on a brown file, and **Stop Tracking
This File** on anything tracked — which keeps your copy and sends the removal
with your next lot of work.

**Send my work** (⇧⌘S) reviews what is going in a list with checkboxes, then
commits and pushes as one action. There is no "saved here but not shared" state
to be confused by.

**Get the latest** (⇧⌘D) fetches and fast-forwards. Never a plain `pull`, which
can start a merge and leave a conflicted folder — exactly where people lose
work.

### What happens when two people change the same thing

Git refuses a push whenever the shared copy has moved on *at all*, even when
nobody went near your files. Diptych treats that as its own problem: it fetches,
replays your commit on top, and pushes. **So you can send one file while another
is still contested** — which every other Git client manages, and refusing it was
a Diptych limitation rather than a Git one. There is a setting to switch that
off for anyone who would rather nothing arrived unasked.

When a file you did *not* tick genuinely clashes, Diptych **asks before doing
anything**, with the folder untouched, one file at a time and a tick to answer
for the rest:

1. keep a copy of yours and take theirs
2. keep yours — theirs is discarded here
3. cancel the whole send

Only files where both sides changed the *same lines* raise the question; where
they did not, Git merges them and your copy ends up with both changes.

**A file you did not tick is never renamed, replaced or annotated.** No conflict
markers appear anywhere, ever.

---

## Comparing two files

**⌘D**, the File menu, or a toolbar button: two files side by side, which is the
shape the application is named after. Two files ticked in one pane, or one in
each.

The diff itself is the standard library's; what Diptych adds is the alignment —
a line rewritten is shown as one line rewritten rather than a deletion followed
by an addition, and a run of changed lines counts as one difference, because
that is what "next" means to a reader. **The words that actually changed are
picked out** within the line, word by word.

There is find, jumping between differences, *only what differs*, *ignore
spacing*, and wrapping that either side obeys or neither does.

### Editing

A padlock on each side, and **only one opens**. To work on the other file you
save, close, and compare again. That is restrictive on purpose — editing both
halves of a comparison in one sitting invites losing track of which is which —
and it makes everything else unambiguous.

Return splits the line where the caret is, Backspace at the start joins it to
the one above, Escape puts the line back, and Tab is a way out that is not the
mouse. One visit to a line is one step of undo. **Take a whole difference from
the other side** with one press, undone with one press.

Saving keeps what is invisible and easy to destroy: the line ending the file
arrived with, whether it ended in a newline, the encoding it had to be read as,
and its permissions, owner and extended attributes. An unchanged file is never
rewritten. A file changed by something else since the window opened is refused
rather than overwritten.

**Replace "name"** appears when you are comparing a file with its own
`(my version)` copy: one press saves it, puts it in the original's place, and
sends the old version to the Trash.

---

## Scripts

An expert can put scripts in `~/.diptych/scripts` and everyone else gets them as
menu commands. **Off by default.**

A script says when it applies in comment lines at the top:

```sh
#!/bin/sh
# name: Make a zip of these
# description: Puts what is selected into untitled.zip, beside it.
# apply-to: file, directory, link
# extensions: txt,png
# args: 1,
# only-under: ~/Documents
# call: $0 $@
```

The command line is **split into arguments before anything is substituted, so no
shell is involved at any point.** There are no quoting rules to learn and a file
called `my notes (draft).txt` needs no thought from anybody.

A mistake in a header comes back as a sentence its author can act on, listed at
startup — including a misspelt setting, which would otherwise do nothing and say
nothing.

The output window shows the command line, the output as it arrives, **Stop**
while it runs, and the exit status — in red when it is not zero, since a script
that fails while printing plausible output is otherwise indistinguishable from
one that worked.

### What it will not run

The danger this invents is not a dishonest expert but a script that arrives by
post. So Diptych refuses anything that:

- came from outside this Mac (it carries a quarantine mark);
- belongs to somebody else;
- can be written to — a download lands as `rw-r--r--`, so requiring no write bit
  makes installing a script an act rather than an accident, and means an
  approved script cannot change afterwards;
- anybody else can read, because a script is a fair place to keep something
  private.

**Nothing lifts these**, developer mode included: a check anybody can switch off
is not a check, and a script written under a relaxed rule would first be tried
under the real one on the day it matters. You are asked before a script runs for
the first time, and again whenever it changes. Every rule is checked again at
the moment of running, not only when the folder was read.

---

## Looking inside things

**Space on a folder** now lists what is in it — folders first, with sizes and
dates — instead of a large blue icon and a size.

**Space on an archive** lists its contents: zip, tar, and tar compressed with
gzip, bzip2, xz or the old compress, all through the system's own `tar`.

Neither waits for a disk. The page appears at once saying *Reading…*, the
listing is fetched behind it, and it fills in when it arrives.

---

## Everything else that is new

- **New from Clipboard** (⇧⌘V) makes a file from whatever was copied — a text
  file, or a picture as PNG, JPEG or PDF, set in Settings, with *ask each time*
  and *off* as choices. A drawing copied as vector art stays vector art.
- **A configurable toolbar.** Practically every menu command can be a button,
  arranged left, centre or right, in a settings pane of its own.
- **New File**, and a numbered suggestion when `untitled` is taken.
- **A Markdown preview**, rendered rather than shown as source.
- **Progress while copying and moving**, with cancellation and a choice about
  what to do with what was already written.
- **F1 copies a prompt** about the selection to the clipboard — and sends it
  nowhere. The template lives in `~/.diptych/prompts/prompt1.tmpl` and is yours
  to edit. File names are checked for control characters that could hide a
  prompt injection behind what you see.
- **Ask before quitting** (⌘Q sits one key from Close Window), switchable.
- **Folders before files**, switchable.
- **A symlink's target** on hover, and editable in the Info window.
- **The Attributes tab lists attributes it cannot read**, marked *protected*,
  rather than leaving them out.

---

## Fixes worth knowing about

- **Saving a file whose metadata cannot be copied.** macOS said "you do not have
  permission to save the file" about files that were perfectly writable. The
  real cause is a system-private attribute left by any sandboxed program that
  has opened the file, which no process may even read. Such files save now — and
  when something genuinely cannot be done, the message is worked out from the
  file rather than repeated from the system, and says plainly when there is
  nothing you need to change.
- **A folder written on Windows** no longer compares as double-spaced.
- **A renamed folder stays selected.** So does a new folder, and a folder copied
  into the other pane.
- **History steps over folders that have been deleted**, instead of bouncing off
  the first one and making everything older unreachable. And it never walks from
  a folder to the same folder.
- **A sleeping disk no longer freezes the application at launch.** The sidebar
  was asking each row for its icon while drawing it, and a volume's icon can
  come off the volume.
- **Several sleeping disks no longer stop it altogether.** Blocking work is now
  bounded well below the point where the system stops making threads.
- **Comparison windows have names**, so they can be told apart in the Dock.
- **Auxiliary windows are not restored empty** after a restart.

---

## Upgrading

Nothing to do. Settings carry over, and everything new is off by default:
version tracking, scripts, and the automatic check.

If you had a `config.json` from 1.0.0, it is read as it stands; the settings
added since take their defaults.

---

*501 tests.*
