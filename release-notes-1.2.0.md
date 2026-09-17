# Diptych 1.2.0

Nineteen changes since 1.1.0. Five of them are new things the application does;
the rest make those work, or fix what went wrong on the way.

The five are **suggested names** from Apple Intelligence on this Mac, **Undo and
Redo** for what Diptych does to files, **Rename Many**, two new tabs in the
**Info window** — what has a file open, and what a file says about itself — and
**Text Edit**.

---

## Suggested names, from Apple Intelligence on this Mac

Diptych can read the start of a file and suggest a name for it. It is **off by
default** and switched on in Settings, in a tab of its own: **Apple
Intelligence**.

**Rename with Suggested Name** (⌘F2) opens the rename field with a suggestion
already in it, and **New from Clipboard** names the file it makes from what is
in it. A suggestion always lands in the rename field for you to accept, change
or throw away; nothing is ever renamed without you pressing Return.

It reads text, the text of a PDF, and what Vision sees in a picture — the words
written in it and what it seems to show.

### On this Mac, and nowhere else

Only the language model that runs on the Mac itself is used. Apple's Private
Cloud Compute model is listed in Settings as *not available yet*, with the
whole choice disabled: it would send the start of your files to Apple's servers,
and if Diptych ever offers it, it will be a choice you make there.

It needs macOS 26 and a Mac that can run Apple Intelligence. The tickbox can only
be switched on when Apple Intelligence is ready, can always be switched off, and
the line under it says which of those it is.

### The wait

A name takes a second or two. The message stays up for as long as it takes and
**counts the seconds** — *Thinking of a name… 3 s* — so "it took eight seconds"
is something you can say rather than a feeling. **Escape** stops it.

When no name comes back, the message says **why**: more than the model can read
at once, no answer within twenty seconds, content the model would not describe,
a language it does not support, or nothing in the file to go on. It used to
blame the file every time.

### How a name is written

- **A character instead of spaces** — `Budget_meeting_minutes`.
- **Plain ASCII** when UTF-8 is unticked: accents are dropped, other alphabets
  are spelt in Latin letters (Москва becomes Moskva), and anything with no such
  spelling is left out.
- **ä, ö, ü as ae, oe, ue**, for German readers, who take *Ubersicht* for a
  misspelling of *Übersicht*.
- **How much of the file is read** — 100, 500, 1000, 3000 characters, or any
  number. Fewer is quicker but gives the model less to go on.

Whatever the model answers is cleaned into a safe file name first: no path
separators, no control characters, no leading dot, nothing longer than sixty
characters.

### Templates, per folder

What the model is sent is a template you can edit:
`~/.diptych/prompts/names.tmpl`, written with Diptych's own text and notes on
first use. **Placeholders** fill in what is known about the file — `{{content}}`,
`{{name}}`, `{{stem}}`, `{{extension}}`, `{{folder}}`, `{{size}}`,
`{{permissions}}`, `{{owner}}`, `{{created}}`, `{{modified}}`, `{{today}}` and
more — so a template can ask for a date in the name, or the folder's name in it.

A template in `~/.diptych/prompts/names/` that starts with a line such as

```
# under: ~/Documents/Scans, /Volumes/Archive/Scans
```

is used in those folders and every folder inside them. **The nearest folder
wins, whole**; templates are never merged, so what the model was sent is always
one file you can read. They live in `~/.diptych` and not in the folders, so an
archive or a shared drive cannot bring instructions of its own. An edit applies
to the very next name, and Settings lists which template covers which folder,
with any misspelt placeholder or setting.

---

## Undo and Redo

**Edit ▸ Undo** (⌘Z) and **Redo** (⇧⌘Z) reverse what Diptych did to files:
a copy, a move (by key, paste or drag), a rename, a new file or folder, New from
Clipboard, a link, **Move to Trash**, a permission change, and an owner or group
change — from the panes or from the Info window. The menu names the step:
*Undo Move*, *Redo Rename*.

### It asks first

Undoing a copy puts files in the Trash and undoing a move moves them again, and
a keystroke is too cheap a way to do either unseen. The question says what
**was done**, in one sentence, and the button says what pressing it does:

> "draft.txt" was renamed to "final.txt" in "~/Documents".  ⟨Cancel⟩ ⟨Undo Rename⟩

### It does not do harm

- **Nothing is deleted.** Undoing a copy or a new item moves it to the Trash;
  redoing it takes the same item back out.
- **Nothing is done to the wrong file.** Each step remembers which file it was,
  not only its name. A file replaced since by another of the same name is left
  alone, and so is a move back onto a name that is taken or into a folder that
  is gone. Whatever can still be done is offered on its own.
- **What cannot come back is said** before anything happens: an item a copy or
  move *replaced*, a file changed since it was copied, an item emptied from the
  Trash.
- **A step that fails does not block the rest.** Handing a file to another user
  can put it beyond your own reach, and undoing an owner change asks for no
  password. It says which file, why, and that Change Owner… can do it with
  authorisation — and everything else goes ahead, and the next undo still works.

### Many at once

**Edit ▸ Undo or Redo Many…** (⌃⌘Z) lists the steps with checkboxes — Shift-click
ticks a run, as in a pane — and undone steps separately, to do again. They are
carried out newest first.

One history for the whole application, as in Finder, fifty steps deep. It is not
kept after quitting: the paths it holds may describe a world that has moved on.
While you are typing in a name field, ⌘Z undoes the typing, as it should.

---

## Rename Many

**⌃⌘R**, File ▸ Rename Many…, or the right-click menu: one regular expression
over a whole folder, in a window of its own. Every file is listed with the name
it would get **before anything happens**; files that do not match are dimmed, or
hidden.

The search is **always** a regular expression and **always** matches the whole
name — half a name matched is half a name replaced — so there is no box to tick.
The replacement uses `$1`, `$2` … for the groups:

```
Search    (\d{4})-(\d{2})-(\d{2}) invoice\.pdf
Replace   Invoice $3.$2.$1.pdf
```

**Nothing is renamed until all of it can be.** It refuses, naming the files, two
files that would end up with one name, a name already taken by a file that is
not being renamed, and a name the disk would not accept.

**A chain is ordered, not refused.** `A` to `B` while `B` to `C` renames `B`
first. Two files **swapping** names — `a-b` and `b-a` with `(.*)-(.*)` →
`$2-$1` — cannot be ordered, so one steps aside under a temporary name and comes
back, and the window says so.

The whole rename is **one undo step**.

---

## The Info window

Two new tabs, which make seven, so the window is wider.

### Open By

The programs that have the file **open**, whether for writing or only for
reading — and for a folder, what is open **inside** it and which program is
working in it, which is what stops a folder being moved.

It asks the kernel directly, as `lsof` does, without starting another program.
Two things it cannot do, and says:

- **Other users' programs cannot be looked inside** without root. The tab gives
  the numbers — *218 of 284 programs could be looked inside* — and reads *no
  program of yours has this file open*, never *nobody has*.
- **Open is not locked.** Most programs holding a file open are only reading it.

It is a snapshot with the time on it and a **Look Again** button, not a live
list.

### Details

What the file says **about itself**:

- **Pictures** — size, resolution, colour, orientation, and EXIF, TIFF, IPTC,
  PNG, GIF, HEIC and **GPS**, so a photograph's location is visible rather than
  merely present.
- **PDF** — pages, the first page's size in points and millimetres, version,
  encryption, whether printing and copying are allowed, title, author, dates.
- **Sound and film** — length, picture size, frame rate, formats, sample rate
  and channels.
- **Everything else** — what Spotlight already knows, which covers Word files,
  spreadsheets and presentations without opening them.

**Read only, deliberately.** These attributes live inside the file, so changing
one means rewriting the file — re-encoding a photograph, or unzipping and
rezipping a document — and a file manager that does that behind a text field has
done more harm than the typo it fixed.

---

## Text Edit

Right-click a file ▸ **Text Edit** opens it as plain text in a small window of
Diptych's own, whatever application the file would normally open in. Typing,
undo, find and replace (⌘F), wrapping, and Save (⌘S).

- **Nothing rewrites what you type**: no curly quotes, no dashes, no spelling
  correction. In a script or a CSV each of those silently changes what the file
  means.
- **The file is saved as it came**: its line endings, its final newline, its
  encoding, its permissions, owner and extended attributes. Text that cannot be
  written in the file's encoding is refused rather than mangled.
- **A file changed elsewhere is not overwritten** without asking. A file you
  cannot write to opens read-only and says so. A binary file is not opened.
- **A file cannot be open in Text Edit and a comparison window at once**: each
  would save over the other without a word.

**Bin View is now Bin Edit**, since it has always been able to change the file.

---

## Everything else that is new

- **The filter finds a fragment.** `inv` lists every invoice, without two stars
  around it. A filter with `*`, `?` or `[` in it is still a shell pattern, so
  `*.txt` and `inv*` mean what they always did.
- **Text that is neither UTF-8 nor marked with its encoding** opens as Windows
  Latin-1 or ISO Latin-1 instead of being refused — in Text Edit and in
  comparisons — and the window says which.
- **A Swiss badge on the icon**, as Tychedit wears: the flag's red and its cross,
  in the corner.

---

## Fixes worth knowing about

- **Renaming or moving a file under version tracking no longer untracks it.**
  The new name went brown and the old name was sent as a removal, so the file
  disappeared for everyone else. On a Mac it was worse: renaming `Untitled.png`
  to `untitled.png` left **both** names in the shared copy, and the folder showed
  blue for ever with no file on screen to account for it. Renames and moves now
  keep the file tracked, show as *renamed*, and send the old name's removal with
  the new name.
- **Quick Look keeps up** when the file it is showing is trashed or renamed. It
  used to say *No items selected* while the pane had already moved on to the next
  file. With nothing left to show, it now closes.

---

## Upgrading

Nothing to do. Settings carry over, and the new ones take their defaults:
**Apple Intelligence is off**, and suggested names keep spaces, keep UTF-8 and
read 3000 characters until you say otherwise. The naming template is written to
`~/.diptych/prompts/names.tmpl` the first time it is needed; an existing
`prompt1.tmpl` for F1 is not touched.

New shortcuts: **⌘F2** Rename with Suggested Name, **⌃⌘R** Rename Many, **⌃⌘Z**
Undo or Redo Many.

Diptych still runs on macOS 15. Suggested names need macOS 26 and an Apple
Intelligence Mac; everything else in this release works without it.

---

*671 tests.*
