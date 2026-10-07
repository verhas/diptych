#  Diptych

*Diptych — pronounced ‘deep tech’ — a two-pane AI driven file manager for macOS.*

https://verhas.github.io/diptych/


A two-pane (Norton Commander style) file manager for macOS, in Swift + SwiftUI.

## Build and run

In Xcode: open `Diptych.xcodeproj` and press ⌘R.

From the terminal:

```sh
./build.sh          # build (Debug)
./build.sh run      # build, quit any running copy, relaunch
./build.sh release  # build optimised
./build.sh clean    # delete build products
./build.sh path     # print the path of the built .app
./build.sh stop     # quit a running instance
```

`./build.sh run` is the ⌘R equivalent. The script hides xcodebuild's output
unless something goes wrong, in which case it prints the compiler diagnostics
and exits non-zero.

Requires macOS 15+ and Xcode 26. Signed ad-hoc, so it runs locally without a
developer account.

## Keys

| Key | Action |
| --- | --- |
| `Tab` | switch active pane |
| `Return` | enter directory / open file |
| `F2`, or click the name of an already-selected row | rename in place (base name pre-selected, as in Finder) |
| `F4`, `F9`, `⌥⌘P`, or click the permissions of an already-selected row | edit permissions in place, for the whole selection |
| `⇧↩` | while renaming: commit and move to the *next* row -- the one that followed this file before the rename, so you can name a run of files in sequence |
| `F3` | view (opens in the default app) |
| `F5` | copy selection to the *other* pane |
| `F6` | move selection to the other pane (the moved files stay selected there) |
| `F7` | new folder |
| `F4` | edit permissions (also on the function bar) |
| `F8`, `⌫`, `⌦` | move to Trash, with confirmation; the cursor lands on the row that followed the deletion |
| `⌘⌫`, `⌘⌦` | move to Trash immediately, no confirmation |
| `⌘=` | show the active pane's folder in the other pane |
| `⌘2` | one pane / two panes |
| `⇧⌘.` | show/hide hidden files (as in Finder; plain `⌘.` is the system's "cancel") |
| `⌘N` / `⌘T` | new window / new tab -- each with its own two panes, titled by folder |
| `Space` | Quick Look preview; arrow keys keep walking the listing and the preview follows. Space or Escape closes it. Files the system has no preview for (`.env`, `.gitconfig`, extension-less scripts) are shown as text when they sniff as text. F2 works with the preview open, so you can look at a scan and name it |
| `⌘C` `⌘X` `⌘V` | copy / cut / paste files, via the system pasteboard (works with Finder both ways) |
| `⌘[` `⌘]` | back / forward through the active pane's directory history |
| `⌘I` | Info window for the selected file (exactly one) |
| `⌥↩` | run the selected script or command-line tool, asking for its arguments |
| `⌘A` | select all -- in the path box it selects the text, otherwise every row |
| `⌃⌘V` | paste as a **symbolic link** to what was copied, rather than a copy of it |
| `⌥⌘C` / `⇧⌥⌘C` | copy the selected file names / full paths as shell arguments |
| `⌃⌘C` | copy what is *in* the selected file -- text as text, a picture as a picture |
| `` ⌃` `` | show or hide the agent terminal |
| `⌘U` | swap the left and right panes |
| `⌘⇧G` | go to folder -- a file's path goes to its folder, selects it and opens it, as Return on its row would; a path that does not exist is refused and the editor stays open; Escape returns to where you were |
| `↑` `↓` | move the cursor; typing letters jumps to a name (type-select) |
| `Home` `End` | first / last row |
| `PgUp` `PgDn` | one screenful |

Right-click a row for Open / Copy / Move / Rename / Reveal / Trash; right-clicking
a row outside the current selection acts on that row, not on what was selected
before. Double-click
anywhere in a row opens it. Clicking in a pane makes it the active one, so an
operation always applies to the pane you just clicked in. Symlinks to
directories are followed to their target, as in Finder; opening a broken one
raises a message that fades on its own. The toolbar carries the one/two pane toggle and the
hidden-files toggle.

Everything also lives in the **Files** menu with ⌘ equivalents, because macOS
maps F1-F12 to brightness/volume unless the user ticks *System Settings >
Keyboard > Use F1, F2, etc. as standard function keys*.

## State

`~/.diptych` is a directory. Session state lives in `~/.diptych/state.json`:
JSON, pretty-printed, keys sorted, slashes unescaped. Each window gets a slot,
holding its frame, both panes' directories and sort order, which pane was
active, and the toolbar toggles. An older single-file `~/.diptych` is converted
on first launch rather than discarded.

Configuration will get its own files in that directory, in a format that takes
comments -- TOML is the obvious candidate, and unlike YAML it needs only a small
parser. JSON stays where it is: state is written by the app and read by nobody.

The extension point is `PaneState` in `Model/AppState.swift`. Add a property
there plus a line in `PaneModel.snapshot` and `restore`, and it is saved,
reloaded, and carried across a pane swap -- the store, the window code and the
JSON handling need no changes.

## Unreadable folders

A directory macOS refuses to open looks exactly like an empty one, so a pane
that cannot read a folder says so over the list instead of showing nothing --
with a button to Full Disk Access when the refusal was TCC.

Time Machine volumes are the usual case: `contentsOfDirectory` on one throws
`NSFileReadNoPermissionError` (underlying `EPERM`) unless the app has Full Disk
Access, even though `stat` succeeds and the volume mounts normally. `ls` fails
on it too, so this is macOS policy rather than anything the app can work around.

Note that Full Disk Access lets a Time Machine volume be *opened*, but its
backups still will not appear as folders: they are APFS snapshots, not
directories. `diskutil apfs listSnapshots` shows them, and only an in-progress
backup exists as a real directory. Finder synthesises that listing and mounts a
snapshot when you enter one; Diptych lists what the file system actually holds.

To grant access: System Settings > Privacy & Security > Full Disk Access, then
add the built app. A debug build lives under `~/Library/Developer/Xcode/DerivedData`,
so add the binary `./build.sh path` prints.

## The path bar

`⌘G`, `⌘⇧G`, or a click on the path turns it into an editor with **shell-style
completion**. The three differ only in what is selected when it opens:

| | Opens with |
| --- | --- |
| `⌘G` — **Go** | the whole path selected, so the first keystroke replaces it |
| `⌘⇧G` — **Go to Folder**, or a click | the caret after the trailing separator, ready for a child's name |

That is the distinction worth having: going somewhere else entirely, against
going somewhere below here.

**Anything not starting with `/` or `~` is relative to the pane**, as in a
shell: `Downloads` is a child of where you are standing, `./Downloads` says the
same thing explicitly, and `../` is the parent. That is what makes `⌘G` worth
having -- select all, type a child's name, Return, without going near the End
key. Tab completes relative text too, and leaves it relative: rewriting `../Doc`
into an absolute path under the cursor would be its own kind of surprise.

This was also a bug. Relative text used to be resolved against the *process's*
working directory, which for an app launched from the Finder is `/` -- so typing
`../` went to the root of the disk instead of to the parent of where you were. Type `~/Dow` and the rest of the name appears ahead of the cursor
in grey; **Tab** takes it, and takes it again inside the directory it just
completed. Several matches extend as far as they agree and stop -- `alpha-one`
and `alpha-two` complete to `alpha-` and wait, exactly as a shell does. Right
arrow accepts a suggestion, Return takes it and goes. Only directories are
offered, since a file path is refused on commit anyway, and a hidden entry
appears only once its dot has been typed.

The text turns **red** while it does not name a directory that exists, so a typo
shows before Return rather than after it. Judged on the **whole field, suggestion
included**, because that is what Return commits: colouring only the typed part
left `~/Dow` red while the field plainly read `~/Downloads/`, and left it red
after a click moved the cursor, since the text had not changed and nothing
recoloured it.

The colouring happens once the text has settled rather than on each keystroke.
The suggestion arrives a runloop turn after the character that prompted it, so
recolouring immediately would flash red on every letter of a name that completes.

Opening the editor puts the current directory in it **with a trailing separator**
and the caret at the end -- not selecting everything, which is what AppKit does
by default. What you almost always want next is to type a child's name, and Tab
then completes inside this directory rather than re-completing its own name.
`⌘A` still selects the lot when you do want to replace it.

It is AppKit (`PathField`), because the suggestion is inserted into the field and
left *selected* -- which is what makes typing straight through it replace it --
and SwiftUI's `TextField` offers neither a selection range nor a per-range
colour. The selection is drawn grey on a soft background rather than the usual
white on blue, so it reads as a suggestion rather than as something chosen.

One thing that has to be got right: a suggestion must not be offered while text
is being *deleted*. Backspace leaves the cursor at the end just as typing does,
so without suppressing it every backspace grew the completion straight back and
the path could not be shortened.

## Sidebar

`⌃⌘S`, or the toolbar icon, shows a sidebar of **Volumes** and **Favourites**.
Clicking a row opens it in the active pane.

The highlighted row is not stored: it is *derived* from where the active pane
actually is, and opening happens in that selection's setter. Stored selection
looks equivalent and is not. Click **github**, then go into **diptych**, then
click **github** again: the row was still highlighted, so the click assigned the
value already there, which is not a change, so nothing happened. Deriving it
means the row deselects as soon as you leave the folder, and clicking it is a
change again.

Drag any **folder** from a pane onto the sidebar to add a favourite -- files are
refused, since a favourite is somewhere to go. Drag a favourite up or down to
reorder it. Remove one with **its context menu**, and only there: `⌘⌫` always
trashes files in the pane. It used to remove the selected favourite whenever one
was selected -- which, since selecting a favourite is how you navigate, was most
of the time -- so a keystroke aimed at a file took a favourite instead, and a
keystroke aimed at a favourite could take files. Removing a favourite is rare and
cannot be undone; it does not deserve a shortcut. Volumes cannot be
reordered; their order belongs to the system. Favourites are global and live in `config.json`;
whether the sidebar is open is per window, in `state.json`.

Ejectable volumes carry an eject button, and an Eject item in their context
menu. Ejectability is not `volumeIsEjectable`: external APFS disks routinely
report false for it while being perfectly ejectable, so the test is "neither the
root file system nor internal". Ejecting takes the whole device, as Finder does,
and any pane sitting on the volume is moved home first.

Volumes track mounts and unmounts through NSWorkspace notifications -- a disk
appearing touches no directory a pane watches, so the list has to be told.

There is still only **one** drop destination for the whole window, with the
sidebar recognised by pointer position. SwiftUI gives every `.dropDestination` a
window-sized platform view, so a second one would overlap the first and swallow
its drops.

Within a pane, the drop goes where the pointer is when it lands: onto a folder
row (or `..`), into that folder, whether or not spring-loading has opened it
yet; anywhere else, into the pane's folder. It is read from the pointer, not
from the folder spring-loading is waiting on -- the last position update of a
drag arrives with the button already up and clears that. An app is not a folder
to drop into. A row stops flashing within a moment of the drag ending, however
it ends: the flash is drawn from the clock rather than a repeating animation,
and the target is let go once position updates stop.

## Sounds

A short sound after a copy, a move, or a move to Trash, chosen in Settings >
Sounds from the system set. One **Play sounds** switch turns all of them off;
"None" silences a single event. Picking a sound plays it, even while sounds are
off -- choosing one should be audible.

## Tag colours

A file carrying one of the seven colour tags gets that colour behind its whole
row, not just a dot. With several colour tags the first one wins -- a row has
one background. Tags are read for every listing, not only when the Tags column
is switched on, since the colour is part of drawing the row.

## History and filtering

Each pane has its own bar above the path: back and forward arrows on the left,
a filter on the right.

**Back / Forward** (`⌘[` and `⌘]`) walk that pane's own history of visited
directories. Going somewhere new after going back discards the forward trail,
as a browser does. History is per-session; it is not saved.

**The filter** matches a fragment of the name by default: `inv` lists every
invoice, because typing two stars around every word was the common case and the
fiddly one. A filter with `*`, `?` or `[` in it is a shell pattern instead --
`*.txt`, matched by `fnmatch`,
the same routine the shell uses -- or a regular expression when **RegEx** is
ticked, where the equivalent is `.*\.txt`. The expression is anchored, so it
filters the way a glob does rather than finding a fragment anywhere in the name.
Matching is case-insensitive, because the file system is. A regex that will not
compile turns the field red instead of silently matching nothing.

While the field holds anything, a grey **⊗** sits at its right-hand edge and
clears it in one click, the way a search field does. It appears only when there
is something to clear -- a button that is always there reads as part of the
field rather than as something to press.

**Hide** decides what happens to items that do not match:

- off (default) -- they stay listed but greyed out, cannot be selected, and the
  arrow keys step over them
- on -- they are not listed at all

`..` always matches; it is navigation, not content.

## Previewing a .DS_Store

Space previews the selected file through Quick Look. `.DS_Store` has no
generator, so the panel used to show a name and a size for a file that is
actually full of readable structure -- so Diptych decodes it and previews an
HTML rendering instead.

**What is in one.** The container is `Bud1`, Apple's generic "buddy allocator"
block store: four bytes of magic, the string `Bud1`, then a table of block
addresses where `addr & ~0x1F` is the offset and `addr & 0x1F` is `log2(size)`.
One named block, `DSDB`, points at a B-tree whose records are sorted by
filename. Each record is a filename in UTF-16, a four-character key, a
four-character type, and a value.

The records describe *the entries of the directory the file sits in*, not the
directory itself: `Iloc` is where an icon sat, `bwsp` an embedded binary plist
of window settings, `lsvC` the list columns and their widths, `cmmt` a Spotlight
comment, `lg1S`/`ph1S` sizes, `moDD` a modification date.

The rendering groups records by the item they describe, expands the embedded
property lists, turns `{{310, 275}, {1727, 1040}}` into `1727 × 1040 at
(310, 275)`, and **plots the icon positions** -- coordinates are the one part of
the file that is genuinely a shape, and a picture of how the folder was arranged
says more than a list of number pairs. Only the spacing is scaled to fit, and
never below half: the dots and the names keep a readable size however many
icons there are, long names are shortened (the whole name shows on hover), and
a map larger than the preview scrolls in its box. Keys it cannot name still
show their bytes. A file that fails to decode gets a page saying so, rather than falling
back to the empty panel: "this is not a `Bud1` file at all" is worth being told.

Three things the format does that a first attempt gets wrong, all found by
running the decoder over the 130 real `.DS_Store` files on this machine:

- **The rightmost child of an internal node trails the last record.** Walk only
  the children that precede records and you lose everything past the final key
  -- silently, with a plausible-looking result. `~/github/.DS_Store` declares 80
  records and the first version of this decoder returned 2, without an error.
- **`moDD` is little-endian**, an IEEE double of seconds since 2001, while every
  other number in the file is a big-endian integer.
- **An unknown value type cannot be skipped**, because a value's length is
  implied by its type. Once one is missed, the rest of the node is garbage read
  as records, so the decoder fails instead.

Every read is bounds checked and every limit explicit -- 1 MB of file, 20,000
records, a cycle guard on the tree walk -- because this is an undocumented binary
format found in the wild, and a file manager that crashed on a file it merely
tried to preview would be worse than one that previews nothing. One of the 130
files here turned out to hold sixteen bytes of ASCII reading `Input length = 1`;
it is reported as not being a `.DS_Store`, which is exactly what it is not.

## Rename Many

**⌃⌘R**, or File ▸ Rename Many…, or the right-click menu: one regular
expression over a whole folder, in a window of its own. Search and Replace at
the top, the folder's files below, each shown with the name it would get. The
search is **always** a regular expression and **always** matches the whole name
— half a name matched is half a name replaced, which in a bulk rename is a
folder full of damage — so there is no RegEx box to tick. The replacement uses
`$1`, `$2` … for the capturing groups. Non-matching files are dimmed as the
pane filter dims them, or hidden with a checkbox. ↑ and a double-click on a
folder navigate.

**Nothing is renamed until the whole plan is sound.** `RenamePlan` works it all
out first and refuses, naming the files:

- two files that would end up with the same name — compared case-insensitively,
  since this disk does not tell `Notes` from `notes`;
- a name already taken by a file that is *not* being renamed;
- a replacement that cannot be a file name at all.

**A chain is ordered, not refused.** `A`→`B` while `B`→`C` is sensible: `B`
moves first. That is a topological sort over "my new name is somebody's old
name". A **cycle** cannot be ordered — `a-b` and `b-a` with `(.*)-(.*)` → `$2-$1`
swap — so one file steps aside under a `.diptych-rename-…` name and comes back
at the end, which the window says out loud. A step that fails stops the run,
because the steps after it were ordered on the assumption that it had happened;
what was done is reported and can be undone.

The whole rename is **one** undo step. Reversing it is the same ordering problem
read backwards, so the history's checks understand a chain: a name occupied now
may be freed by an earlier step, and a file that stepped aside does not exist
yet.

## Quick Look keeps up

Space previews the selection, and the panel follows the cursor. It also follows
what happens to the file: **trashing or renaming the previewed file** used to
leave the panel reading *No items selected* while the pane had already moved the
cursor to the next file. Quick Look drops its data source when the item it was
showing goes away, and `reloadData` alone does not bring it back — the source
has to be asserted again and the *item* refreshed, not only the list. With
nothing left to show, the panel closes rather than sitting there looking broken.

## Undo and Redo

**Edit ▸ Undo** (⌘Z) and **Redo** (⇧⌘Z) in a pane window reverse what Diptych
did to files: a copy, a move (by F5/F6, paste or drag), a rename, a new file or
folder, New from Clipboard, a link, **Move to Trash**, a permission change, and
an **owner or group change** — from the panes or from the Info window. The menu
names the step: *Undo Move*, *Redo Rename*.

**Edit ▸ Undo or Redo Many…** (⌃⌘Z, caught in `KeyRouter` because the menu
never receives that combination — something between the keyboard and the menu
bar takes it, exactly as it takes ⌘=) does several at once: a scrollable list of
steps with checkboxes, Shift-click for a run of them as in a pane, and any
undone steps listed separately to do again. They are carried out newest first.

Every undo and redo **asks first**, because undoing a copy puts files in the
Trash and undoing a move moves them again, and a keystroke is too cheap a way
to do either unseen. Cancel leaves the step where it was.

The question says what **was done**, in the past tense, and the button says
what pressing it does:

> "draft.txt" was renamed to "final.txt" in "~/Documents".  [Cancel] [Undo Rename]

Written as the reversal it read backwards, and split one rename over two lines
with nothing to say which name came first. One kind of quotation mark, around
names and folders alike, and a sheet wide enough for the sentence to stay on
one line.

* **Nothing is deleted.** Undoing a copy, a new item or a link moves it to the
  Trash; redoing takes that same item back out of the Trash.
* **Nothing is done to the wrong item.** Each step records which file it was,
  not only its name. A file replaced since by another of the same name is left
  alone and the question says so; so is a move back onto a name that is taken,
  or into a folder that is gone. What can still be done is offered on its own.
* **What cannot come back is said.** An item that a copy or move *replaced* is
  gone, and a file changed since it was copied goes to the Trash as it is now —
  both are mentioned before anything happens. An item emptied from the Trash
  cannot come out of it again.
* **A step that fails is reported and dropped, not left in the way.** Handing a
  file to another user can put it beyond your own reach, so putting it back may
  be refused — and undoing an owner change asks for no password. It says which
  item, why, and that Change Owner… can do it with authorisation. Everything
  else in that same undo still goes ahead, and the next undo still works.
* A renamed or moved file in a Git folder stays tracked when it goes back.

One history for the whole application, as in Finder, fifty steps deep, kept in
memory: after a restart the paths it holds may describe a world that has moved
on. While a rename field or the path bar is being typed in, ⌘Z undoes the
typing, and in a comparison window it is that window's own undo.

## Comparing two files that are not text

⌘D on two files opens the comparison window. When either of them is **not
text**, a line-by-line comparison has nothing to say and the machinery around
it — find, wrap, ignore spacing, the padlocks — is all about lines. So the
window shows the one thing worth knowing, and an OK button:

* **the files are exactly the same**, byte for byte;
* **they differ from the very first byte**;
* **they differ, but their first N bytes are identical** — with where they part,
  in decimal and in hex;
* or **one is exactly the beginning of the other**, which is the truncated-file
  case and worth its own sentence.

Sizes are given twice, rounded and exact: "5 KB (5'120 bytes)". The files are
read a megabyte at a time and the comparison stops at the first difference —
two disk images are not going into memory to answer a question usually settled
by the first kilobyte.

## Text Edit

Right-click a file ▸ **Text Edit** opens it as plain text in Diptych's own
editor, one window per file, whatever application the file would normally open
in. It is small on purpose — typing, undo, find and replace (⌘F), wrapping, and
Save (⌘S) — and careful where general editors are not:

* Nothing rewrites what is typed: no curly quotes, no dashes from double
  hyphens, no spelling correction, no link detection. In a script or a CSV each
  of those silently changes what the file means.
* The file is saved with the line endings, final newline and encoding it came
  with, the same way a comparison window saves: its permissions, owner and
  extended attributes survive. Text that cannot be written in the file's
  encoding is refused rather than mangled.
* A file changed by something else since it was opened is not overwritten
  without asking. A file that cannot be written to opens read-only and says so.
* A binary file is not opened; the window points to Bin Edit.
* A file open in a comparison is refused, and the other way round, because two
  windows saving one file would each overwrite the other without a word.

Files that are neither UTF-8 nor marked with their encoding are read as Windows
Latin-1, then ISO Latin-1, and the window shows which.

## Bin Edit

Right-click a file ▸ **Bin Edit** opens a hex editor in its own window, one per
file. (It was called Bin View; it has always been able to change the file.) The entry is absent for folders rather than greyed out -- it would be
permanently disabled on half the rows of every listing -- and `showBinaryView()`
refuses a directory again on the way through, because a context menu is not a
security boundary.

Across the top: a radio group for **8 / 16 / 32 / 48 / 64 bytes per line**, and a
**Decimal** checkbox that swaps two-character hex for three-character decimal.
Down the left, the address each line starts at, in hex, widened to fit the file.
Down the right, the characters -- printable ASCII only, everything else a dot.
That is not timidity: control characters have no glyph, and the C1 range renders
as whatever the font feels like, so a raw byte column is how a hex editor
displays gibberish rather than what it displays.

Arrows move a byte, up and down a line, Page Up and Page Down sixteen lines,
Home and End the ends. The keyboard goes through `BinaryKeyMonitor`, an AppKit
key-down monitor, not `onKeyPress` -- which failed three different ways here.
The plain form never delivered Delete at all; an explicit key set rejected every
arrow, because macOS stamps `.numericPad` on all four of them and the guard was
testing for *no* modifiers; and with that fixed the enclosing `ScrollView` took
the arrows for scrolling before the handler saw them. Keys are matched by
virtual key code, positional and so layout-independent -- the same conclusion
`KeyRouter` reached for the panes, for the same reasons. Typing hex digits (or decimal ones) edits the byte under
the cursor and advances when it is complete -- in decimal, `99` is complete as
soon as it is typed, because `99x` cannot be a byte, while `25` waits for a third
digit because `255` can. Delete restores one byte to what the file holds.

**Selecting.** A click picks one byte; press and drag to pull a run out from it,
across as many rows as you like; Shift-click extends from where the cursor
already is, which is how a selection longer than the window is made -- click the
start, scroll, Shift-click the end.

One gesture serves the whole grid, not one per row: a per-row gesture keeps
reporting positions in the row it began in, so dragging downwards only ever ran
left and right along that one line. Rows have a pinned height so a pointer
position is arithmetic rather than hit testing -- a height merely guessed at
would drift further wrong the further down you dragged.

The cursor is **not** scrolled into view while a drag is in progress. Doing so
is a feedback loop: centring the cursor's row slides the content out from under
the pointer, which puts a different row there, which moves the cursor, which
scrolls again -- the view bolted downwards the instant a drag began. Keyboard
movement has no such loop, because the pointer is not what decides where the
cursor goes, so it still scrolls.
Shift with any movement key extends from the anchor; ⌘A takes the whole file. The selection is always a **run**, never a
block: a rectangle over a hex dump covers bytes that are not next to each other
in the file, which is not something any operation could act on. Delete restores
every changed byte in the selection.

**Insert and remove.** **Remove** (⌘⌫) deletes the selected bytes and pulls
everything after them down. **Insert** (⌘/) puts as many zero bytes as are
selected in front of the cursor and pushes the rest up -- selecting four and
inserting gives four zeros, which is the reading of "insert several" that needs
no second control.

That changes the file's length, which changes how saving works. While every edit
is an overwrite the file stays mapped and the changes are a sparse offset-to-byte
map, so opening a 60 MB file costs nothing and saving seeks to each run. The
first structural edit materialises the content into an array, and saving then
writes it whole and truncates to the new length. It is one-way: once the length
can change there is no sparse patch that describes the result.

Either way the write goes **through the same descriptor** rather than replacing
the file, so the inode, its permissions and its extended attributes all survive a
length change -- there is a test that asserts exactly that.

An insert moves every byte after it, so everything keyed by an offset has to move
too, or it starts describing the wrong bytes: the remembered original values and
the record of which bytes are new are both shifted with the content. A byte that
an insert merely pushed along is **not** marked changed -- its value is the one
the file already had. Inserted bytes are, and reverting one is not meaningful:
it was never in the file, so Remove is the command for it.

**Finding.** A find box at the top takes **text or hex** -- `Hello`, or `48 65 6c`
with the spaces optional -- because a hex editor is used for both: looking for a
string inside a binary, and looking for a byte sequence that has no characters at
all. ⌘G and ⇧⌘G repeat it forwards and backwards, ⌘F puts the cursor in the box,
Return searches. Searching then hands the keyboard **back to the grid** --
Escape and clicking the bytes do too. Keeping focus in the box is what left the
cursor stuck in it with no obvious way out, and every hex digit typed afterwards
went into the query instead of into the file. ⌘G is bound twice, on the key
monitor and on a hidden button, because the monitor stands aside while a text
field has focus and a button's shortcut is matched before the responder chain. It wraps, it searches **what is shown** rather than what is on
disk so pending edits are matched, and the whole match is selected. Hex that will
not parse turns the field red, the same signal the pane filter gives a
half-typed regular expression.

The scan walks candidate positions modulo their count rather than building a list
of them -- a list would be sixty million integers for a large file, more memory
than the file itself -- and clamps rather than wraps when the cursor sits past
the last position a match could start at, which going backwards means the last
candidate and not the first.

**Undo** (⌘Z) takes back the last change, insert or removal, a hundred deep --
distinct from **Revert Bytes** (Delete), which restores whatever is selected to
what the file holds. The stack holds *operations*, not snapshots: a snapshot of
the content would be the whole file, while the reversal of an insert is a
removal. Each reversal is recorded as values and applied against whichever
representation is current when it runs, because the first structural edit swaps
representation underneath entries already on the stack -- an entry written in
terms of the sparse map silently did nothing once the content had been
materialised. Saving clears the stack: the reversals describe edits against
content that is now on disk.

**Changed bytes are red**, in both the byte column and the character column, and
stay red until they are written. Nothing reaches the file until **Save**, which
asks for confirmation first and says exactly how many bytes it is about to
overwrite.

Saving writes **only the changed bytes**: the edits are kept sparsely as
offset-to-value, gathered into contiguous runs, and written through a
`FileHandle` seeking to each run. Every other byte of the file is untouched, the
length cannot change, and a 60 MB file costs one seek and one write rather than a
rewrite. It goes through the same permission ladder as the metadata writes, so a
read-only file offers to unlock, write and lock again rather than failing
quietly -- though with no privileged fallback, because patching arbitrary offsets
as root through `dd` is a worse idea than saying no.

The file is memory-mapped and rows are built lazily, so only the visible lines
become views. The limit is 64 MB, past which a different kind of tool is wanted:
at 16 bytes a line, a DVD image would ask SwiftUI for a hundred million rows.

## Previewing Markdown

`.md` is typed `net.daringfireball.markdown`, which conforms to
`public.plain-text` and has no Quick Look generator of its own -- so Space showed
the source. It is rendered instead, through the same hook as `.DS_Store`: HTML
into the scratch directory, handed to Quick Look.

**Nothing is vendored and nothing is hand-parsed.** `AttributedString(markdown:)`
is Foundation's own CommonMark parser with the GitHub extensions, and it already
identifies headings, nested lists, block quotes, fenced code blocks *with their
language*, tables with per-column alignment, links, and inline bold, italic,
code and strikethrough.

What is left is shape. The parser returns a **flat** run of text carrying
`presentationIntent` attributes and HTML is a tree, so the work is turning one
into the other: compare each run's intents with the previous run's, close the
tags that ended, open the ones that began. Blocks are matched by the parser's own
`identity`, not by kind -- otherwise two adjacent list items of the same kind
look like one, and a nested list never closes.

Two things worth knowing. Inside a fence everything is escaped, so a README
documenting HTML shows that HTML rather than running it. And relative image
paths resolve against **the document**, not against the temporary file the
preview is written to, or every image in every README would break.

The one gap: Foundation does not parse task lists, so `- [ ] todo` renders as a
list item whose text begins `[ ]`.

## Font and zoom

Settings ▸ **Appearance** chooses the font the panes are drawn with, and the
size. `⌘+` and `⌘−` step it, `⌘0` returns to 11 pt. The range is 8–28 pt,
clamped on the way in as well, since `config.json` is meant to be hand-editable
and a size of `0` would leave no way back.

Only the **panes** follow it. Settings, the sidebar, dialogs and the function bar
keep their own sizes -- what is being configured is the file listing, not the
chrome around it.

`PaneFont` is the single source, because the pieces have to agree: the
permissions column is drawn by SwiftUI in the listing and by an `NSView` while
being edited, and a point of disagreement between them stops the characters
lining up between the edited row and the rows above it. Permissions stay
monospaced whatever family is chosen -- `rwxr-xr-x` is a grid of nine columns,
and the in-place editor addresses a slot by position.

**Rows do not follow their content.** SwiftUI's `Table` reports
`usesAutomaticRowHeights == true` and then keeps every row at exactly 24 points
whatever is in it -- measured on a settled window with 105 rows and 20-point
text, where the row view was still 24. So `RowHeights` pushes a computed height
onto the `NSTableView` underneath, the same move `ColumnWidths` makes for the
same reason, and by `noteHeightOfRows` rather than `reloadData` because SwiftUI
owns that table's data source.

Icons grow with the text, and **the icon cache keys on the size**. Without that
it would serve the images cached at the old size for the rest of the session --
the same shape of bug as a folder whose custom icon had changed.

`⌘+` deserves a note of its own: it is not a keystroke. The key is `=`, and `+`
needs Shift, so AppKit matches a menu equivalent of `+` only when Shift is held.
The menu carries `⌘+`; `⌘=` -- the same physical key, and what half of everyone
actually presses -- is caught in `KeyRouter`, because a menu cannot hold two
equivalents for one command and a second visible item would be nonsense.

Column widths are stored in points and are *not* rescaled when the font changes,
so a bigger font truncates sooner until you drag. Silently rewriting widths you
set deliberately would be the more surprising behaviour.

## Slow volumes

Opening a USB disk that is still spinning up used to lag the whole app. Three
things were waiting on it, and only one of them had any business doing so.

**`DirectoryLoader` was an actor.** An actor serialises its work, so a listing
that took four seconds held up every listing behind it -- the other pane, and
this pane's next directory, both waiting on a disk neither cared about. Listings
share no state, so the serialisation bought nothing. It is now a plain enum whose
calls run independently.

**`VolumeList.reload()` ran on the main actor** and stats every mounted volume,
which is a syscall each and slow on a sleeping disk. Worse, it runs on every
mount and unmount notification -- exactly when a disk is least ready to answer.
It now enumerates in the background and publishes the result.

**Sidebar icons were fetched during `body`**, once per row per redraw, and a
volume root's icon can come off the disk itself. They are cached now.

### While it loads

A slow volume used to leave the pane showing the *previous* directory while
claiming to be in the new one -- and still accepting clicks. Double-clicking a
row then opened whatever happened to sit at that row index in the directory that
was arriving. So navigating to a different directory now:

- **clears the listing at once**, and the selection with it, so there is nothing
  to click, open, preview or drag out of a listing that no longer describes
  where the pane says it is;
- **disables the table** while the load is in flight, which is the same
  guarantee made twice on purpose;
- **says what it is waiting for**, with a spinner naming the folder;
- **can be cancelled**, by the button or by Escape, which goes back to where it
  came from.

A *refresh in place* does none of this and keeps its rows: a directory watch
firing must not make the pane blink.

Cancelling also takes the abandoned directory back out of the history -- leaving
it there would make Back walk past where you actually are, into somewhere you
never arrived -- and because the sidebar's highlight is derived from the pane's
directory rather than stored, the volume or favourite deselects itself on the
way back with no extra bookkeeping.

Escape is handled in `AppModel` rather than left to the Cancel button's own
shortcut, because `KeyRouter` sees the key first and the button's equivalent
would never fire.

The listing work goes through `BlockingWork`, which uses a dedicated concurrent
queue rather than `Task.detached`. That is deliberate: the Swift concurrency pool
has about as many threads as the machine has cores and expects work to yield
rather than block, so a few multi-second `contentsOfDirectory` calls parked in it
can starve everything else -- including whatever the UI is waiting on. A
dedicated queue grows threads instead.

Cancellation is carried explicitly as a flag, because `Task.isCancelled` means
nothing on a dispatch queue, and it is polled every 256 entries rather than every
one -- the check takes a lock, and a directory of a hundred thousand files should
not pay for it per row. The syscall already in flight cannot be interrupted;
everything after it is abandoned, which is the difference between a stale listing
arriving late and a stale listing being computed in full first.

## Sorting and links

Settings ▸ Appearance ▸ **List folders before files** decides whether
directories are lifted above files or everything is sorted in one sequence by
whatever the column header says. On by default, because that is what every file
manager does -- but it is a preference, not a law, and sorting by size or date is
more useful when the two kinds are not separated. `..` stays on top either way:
it is navigation, not content, and a row that wandered off by date would be a
trap.

A **symbolic link** shows an arrow beside its name, and hovering it now says
where the link points. The target is read once by the loader -- a `readlink` per
symlink is cheap, and doing it during a redraw is not.

- **A link is followed to its end**, through every link it leads to, and the
  arrow is followed by how far that goes:
  - **(n)** in plain text when it reaches a real file or folder through n
    links -- (2) for a link to a link to a file. A direct link shows nothing.
  - a **red dot** when the end is not there, with the number of links before
    it -- **(2)** for a link to a link to nothing; a bare dot is (1), the
    link's own target missing.
  - a red **broken circle with an arrow** when the links go round in a loop,
    with how many links can be followed before one comes round again:
    x5 → x4 → x3 → x2 → x1 → x3 shows **(4)**. A link to itself shows the bare
    circle.
- **Hovering the arrow** says what the link points to -- the next step, as
  stored, whether or not anything is there.
- **Hard links**: a file with more than one name -- several hard links to the
  same inode -- shows the number of names in grey after its own, **(2)**.
- **Right-click ▸ Find Sibling Names (Hard Links to the Same File)…**, on a
  file with more than one name, opens a window that searches for the others.
  It reads outwards from the file: its own folder and everything below it,
  then the folder above without the branch already read, and so on up to the
  top of the volume -- and stops as soon as it has as many names as the inode
  has. Names made near each other, the usual case, are found at once. The
  inode number comes with each folder entry, so nothing is `stat`ed but a
  match; a full search of a startup disk takes about two minutes where
  `find / -inum` takes three and a half. Symbolic links are not followed, and
  `/System/Volumes` is skipped: through the firmlinks it is the same files
  again. Double-click a name, or Show, to see it in a pane.
- **A broken link** -- one that does not lead to anything -- has a right-click
  menu that leaves out what would have to reach the target: Open, Text Edit,
  Bin Edit, Copy ▸ Content and Rename with Suggested Name. What acts on the
  link itself stays -- rename, move, copy, trash, Reveal in Finder -- and so
  does Get Info, where the target can be typed anew to repair it.
- **Right-click ▸ Go to Link Target**, first in the menu, opens the target's
  folder in the pane with the target selected -- a folder as much as a file. It
  is there whenever the link's own target exists, and goes one step: a link to
  a link lands on that link. **Double-clicking the arrow** does the same;
  double-clicking anywhere else on the row opens it, as before.
- **Right-click ▸ Go to Final Target**, under it, is there for a link to a
  link that ends at a real file or folder, and goes straight to that. Not for a
  loop: there is no end to go to.
- **Quick Look on a link** shows the link, not its target: that it is one,
  every step it goes through, and how it ends -- the file or folder with its
  size and date, the name that is not there, or the link the chain goes round
  to.
- **No permissions are shown or edited for a link.** Its own bits are always
  `rwxr-xr-x` on macOS and govern nothing; its target's are what count. A
  selection mixing links and files changes only the files.
- **Whether a link is executable** -- the orange badge -- is its target's to
  say, not the link's.
- **A broken link still takes its name**: a new copy or link beside it is given
  the next free name rather than failing on the one the broken link holds.

The Info window's General tab has the target as an editable field for links,
with a note that follows **what is typed**, updating as you type rather than
describing the link on disk -- it was computed once when the window opened, so it
never moved while editing and still reported a freshly pasted, perfectly good
path as missing. A relative target is resolved against **the link's own folder**,
which is what the kernel does when it follows one, and `~` is expanded. The note
also says whether the target is a file or a folder, since the two behave
differently everywhere else in the app. A broken link is legal and
sometimes deliberate, so that is reported rather than refused, and a relative
target stays relative: rewriting it as an absolute path would change what the
link means once the folder moves.

There is no syscall to repoint a symlink, so applying a new target removes the
link and makes it again. If creating the replacement fails the original is put
back, rather than leaving a hole where a link used to be.

## The menu bar

**File**, **Edit**, **Go**, **Window**, **Help** -- Finder's arrangement, and for
the same reason. There used to be a `Files` menu alongside `File`, which was a
coin toss every time: the two names say nothing about which holds what.

The split is Finder's: what you do *to* an item is in **File** -- Open, Get Info,
Rename, Copy and Move to Other Pane, the ownership and permission commands, Move
to Trash, Reveal in Finder, Open Terminal Here. Where you *go* is in **Go** --
Back, Forward, Enclosing Folder, and the two ways into the path bar.

Open stays in File even though Enclosing Folder is in Go, which looks odd
written down and is exactly what Finder does; following it beats inventing a
third arrangement for people to learn.

## Version tracking

Off by default, in Settings ▸ Version Tracking. Diptych runs the `git` already
on the Mac -- it bundles nothing and links nothing -- because a subprocess
inherits the user's config, SSH agent, credential helper and hooks, which is why
a repository someone else set up works at all. The full argument, the
measurements behind it and the design of what is still to come are in
`git-integration.md`.

Names are coloured to answer one question: **what happens to this file when I
send my work?**

| | |
| --- | --- |
| brown | new -- will *not* be sent unless you track it |
| green | new and tracked -- will be sent |
| blue | tracked and changed -- will be sent |
| red | conflicts with the shared version |
| *no colour* | nothing to send: unchanged, **or ignored** |

Ignored files being drawn normally falls out of that rule rather than being an
oversight: an ignored file and an unchanged file give the same answer. It also
stops a `build` folder painting half the pane. A folder takes the strongest
state inside it, so one holding changes never looks clean.

One `git status --porcelain=v2 -z --branch` per **repository**, cached, gives
every file's state plus the branch and how far it is from the shared copy.
Measured here: 46 ms on a 350-file repository, 67 ms on 1723 files, of which
23 ms is process spawn -- which is why it is one big call rather than several
cheap ones, and cached per repository rather than per directory. It runs through
`BlockingWork` with a deadline, and **decorates the rows after they are drawn**:
no listing ever waits for Git.

The settings pane says which program was found, what it reports itself to be,
and who signed it -- then says plainly that none of that is proof:

> Diptych cannot check that this really is Git. It confirms the file is named
> "git" and that it answers the way Git does, but a harmful program could do
> both of those things. Whatever this program is, it will be able to read,
> change and delete files in your folders, and send them over the internet.

Discovery uses an explicit list of locations, never `$PATH` -- an app launched
from the Finder has a minimal one, so the answer would depend on how Diptych was
started. `/usr/bin/git` is only tried once `xcode-select -p` shows a developer
directory exists, since otherwise it raises the Command Line Tools installer.
Git is run with `GIT_TERMINAL_PROMPT=0` so it can never block waiting for input,
and `GIT_OPTIONAL_LOCKS=0` so a read-only status cannot fight a `git` running in
a terminal.

### Sending and getting

Two commands in the File menu, shown only when the folder is actually tracked:
**Send My Work** (⇧⌘S) and **Get the Latest** (⇧⌘D). Right-clicking a file Git
does not know about offers **Track This File** and **Never Track This**.

**Send is one action.** Commit and push happen together, because "saved here but
not shared" is a state with no place in the user's model and is exactly where
people believe they have shared when they have not. The dialog is a review step
rather than a confirmation: both lists have checkboxes and a tri-state
select-all, so sending only some of your changes is a normal thing to do.

New files start **unticked**. The recovery from forgetting one is a click; the
recovery from sending a private draft or a large export to everyone is a phone
call to whoever set the repository up.

**If the push fails, the commit is undone** -- the files are exactly as they
were and the button still means what it said. *Undone*, not reverted further:
`reset --mixed` unstages everything indiscriminately, so a file the user had
tracked by hand beforehand went brown again when the push failed, as though
that decision had been part of the send. Tracking is a separate, earlier choice
and is put back afterwards -- as is a new file ticked in the dialog, since
ticking means "include it, now and from now on". That is history rewriting, which
is otherwise excluded, and it is safe for one reason only: the commit provably
never left this Mac. Which is why the failure path *fetches first* and checks
whether the commit arrived after all. A connection that dies after the server
accepted would otherwise have its commit deleted from under everyone who can
already see it.

**Get the Latest never runs a plain `pull`**, which can start a merge and leave
a half-merged tree. It fetches and fast-forwards; when it cannot, it says which
files both sides changed and offers to keep a copy of yours -- `chapter3 (my
version).md`, beside the original -- before taking the shared version. The
conflicting set is computed as an intersection through `merge-base`, not as
"everything that differs": someone fifty changes behind has hundreds of
differing files and only two of them are theirs.

**Untracked files count as conflicts too.** The same new file created in two
places is the commonest way for this to happen, and `git diff` never sees an
untracked file -- so it was missing from the list, the dialog offered to keep
copies of nothing, and the update then failed on the very file it had not
mentioned. Untracked collisions are listed now, and their originals are removed
once the copy is safe, since Git refuses to overwrite an untracked file and
there is nothing to restore it from.

**What decides how a clashing file is put back is whether it exists in the
current commit** -- not whether Git has heard of it. A file tracked by hand
before a send that failed is *tracked* and still absent from the last commit, so
restoring it with `checkout --` brought it back from the index and left it
exactly where it was, and the update refused all over again.

**A kept copy is invisible to Git for ever.** `chapter3 (my version).md` matches
the pattern written into `.git/info/exclude`, so it is never offered for
sending, never clashes with anything, and never blocks a later update. It has no
colour in the pane for the same reason every ignored file has none: nothing will
happen to it. Delete it once you have taken what you need.

**A refused send says which files are contested, and offers the right way out
for each case.** Two quite different situations wear the same error from Git.
When nobody has touched the same files -- the common one -- the button is **Get
the Latest and Send Again** and does the whole job in one press: a send is
refused whenever the shared copy has moved on, whichever files were ticked, so
deselecting one cannot help and asking someone to send again by hand is asking
them to repeat themselves. When files *are* contested they are listed by name, and the button becomes
**Keep My Copies, Update and Send** -- one press for all three, because a
contested file blocks the update whether or not it was ticked. Deselecting it in
the send dialog says "do not send this"; it cannot say "leave this folder out of
date". The contested files are dropped from what gets sent afterwards, since
they now hold the shared version and sending them would mean sending back what
just arrived.

The wording says what happened rather than what the reader already knows.
"Your work is saved on this Mac" is not news to the person who saved it; that it
did not reach anyone else is the whole message.

**A refused send is not a dead end.** It almost always means someone else sent
something first, so the dialog offers **Get the Latest** -- with Git's own words
behind a disclosure triangle and a Copy Details button -- rather than handing
over a paragraph of Git and leaving the reader to work out what to do.

Choosing it goes *straight through* the clash rather than stopping to ask about
it. Having said "get the latest" in the full knowledge that the send was
refused, being asked again is a second confirmation for a decision already
made; and keeping copies never loses anything. What was set aside is reported
afterwards, by name -- being excluded from Git, the copies are otherwise
unremarkable in the pane.

The kept copies go into `.git/info/exclude`, not `.gitignore` -- local only,
never pushed, no tracked file touched -- so they cannot be sent by accident and
no collaborator ever sees the rule. When your changes had already been saved as
versions, a bookmark is left pointing at them first, so nothing becomes
unreachable.

## The toolbar

Six buttons is the point at which one person's essentials are another's clutter,
so Settings ▸ Toolbar decides which appear, in what order, and on which of the
three sides a macOS toolbar offers -- left, middle, right. Same shape as the
Columns pane, one draggable list with a checkbox per row, because it is the same
kind of decision and a second arrangement to learn would be a worse answer than
a familiar one.

**Send My Work** and **Get the Latest** appear only in a folder that is actually
tracked. Left out rather than greyed out: a permanently disabled button teaches
nobody anything.

A saved arrangement is repaired when it is read, so a button added in a later
version is appended rather than lost -- otherwise a config written by an older
build would silently hide whatever came next, which reads as the feature not
existing.

## Settings

**Settings...** (`⌘,`) opens a tabbed configuration window. The first tab
chooses which columns the panes show and in what order -- globally, for both
panes and every directory. Name is always present and always first; everything
else can be switched off and dragged into any order.

Available columns: Size, Kind, Date Modified, Date Created, Date Added,
Extension, Permissions, Owner, Group, Tags (the Finder tags).

Column widths are remembered too, in `columnWidths`. SwiftUI's own
`TableColumnCustomization` records widths but -- measured, not assumed -- never
restores them for columns built with `TableColumnForEach`, so the widths are
stored as plain numbers and applied to the NSTableColumns underneath.

Settings live in `~/.diptych/config.json`, separate from session state. Only the
resource keys the enabled columns need are prefetched, so leaving Permissions or
Tags switched off costs nothing per row.

Adding a column means adding a case to `FileColumn`: the settings list is built
from `allCases`, the loader asks each enabled case which `URLResourceKey`s it
needs, and the table and comparator switch on it.

## Editing permissions

Select one or more items, then `F4` or `F9` (or `⌥⌘P`, or click the permissions
of an already-selected row). The nine rwx slots become an in-place editor:

| Key | Does |
| --- | --- |
| `-` `+` `Space` | clear / set / toggle the bit under the caret, then **advance one bit** -- so a whole group types straight through |
| `r` `w` `x` `s` `t` | set that bit **in the current group**, wherever the caret sits in it; the caret does not move |
| `⇧R` `⇧W` `⇧X` `⇧S` `⇧T` | clear that bit in the current group |
| `⌥R` `⌥W` `⌥X` `⌥S` `⌥T` | toggle that bit in the current group |
| `←` `→` | move one bit |
| `⇥` / `⇧⇥` | next / previous group -- the shortcut; the arrows stay bit-by-bit |
| `⌫` | step back one bit and clear it |
| `Home` `End` | first / last bit |
| `↩` / `Esc` | apply / abandon |

Two ways to reach any bit: arrow onto it and use `-`/`+`/Space, or address it by
letter from anywhere in its group with plain / `⇧` / `⌥`.

`s` is setuid in the user group and setgid in the group group; `t` is sticky, in
the other group. Each beeps where it has no meaning. They follow the same plain /
`⇧` / `⌥` convention as `r`, `w` and `x` -- they used to toggle whatever you
pressed, which made them the only keys in the editor with their own rule and left
pressing letters until the right one appeared as the only way to find out.

The caret's group is tinted and the caret bit highlighted, because the letters
act on the group while `-`, `+` and Space act on the single bit.

**setuid, setgid and sticky have no column of their own.** They share the execute
column, shown as `s`, `s` and `t` in place of `x` -- or `S`/`T` when the special
bit is set and execute is not. `/usr/bin/sudo` is `-r-s--x--x` (mode 4511) and
`/private/tmp` is `drwxrwxrwt` (1777). Diptych renders them the way `ls` does and
colours them, and the Info window has a checkbox for each. The leading character
is the file type -- `-`, `d`, `l`, `c`, `b`, `p`, `s` -- not a permission, which
is why nothing in the editor corresponds to it.

While editing, the column heading reads **user**, **group** or **other**
depending on where the caret is. The result is an absolute mode applied to every
selected item -- which is what makes editing several files at once well defined,
and is why permissions can be edited for a multiple selection where a name
cannot.

## F1 — a prompt about the selection

`F1`, or the leftmost key on the bar, describes the selected items and puts that
description **on the clipboard**.

The wording lives in **`~/.diptych/prompts/prompt1.tmpl`**, written out the first
time it is needed and read from there ever after, so it is yours to edit. The
placeholders are `{{count}}`, `{{itemWord}}`, `{{pronoun}}`, `{{isAre}}`,
`{{parent}}`, `{{parentNote}}`, `{{metadata}}` and `{{warning}}`; an unknown one
is left in the text rather than silently emptied, so a typo looks like a typo.
Substitution is a single pass, so a file named `{{metadata}}` cannot reach back
into the template. A missing or empty file falls back to the built-in text --
F1 should still work when a template is half-edited.

The metadata block is delimited by the **words** `BEGIN FILE METADATA` and
`END FILE METADATA`, not by backticks. A fence cannot be described in prose that
is itself inside a fenced document: writing "everything between the ``` fences"
*opens* one, and every later fence then flips between opening and closing -- so
the block meant to contain the names stopped containing them. Sentinel words have
no such property and survive being pasted into an editor, a terminal or a chat
box unchanged.

Owner, group and permissions are read from disk when the pane has not loaded them
-- they arrive only when their columns are switched on, and a prompt should not
lose them for want of a column nobody enabled. A leading dot is called out as
`hidden: yes`, since that is the whole of what hidden means here and it is easy
to miss in a name. It sends nothing, opens no connection, and has
no idea what an LLM is. The whole feature is a formatter; what you do with the
text afterwards is yours.

Which is exactly why the care goes into the text rather than into any network
code. The clipboard is the entire exposure, and it is a shared surface: every
app running as you can read it, clipboard managers archive it, and with Handoff
switched on macOS syncs it to your other devices. "Nothing is sent" is true of
Diptych and is *not* the same as "this stays on this machine."

So the prompt contains:

- **no file contents, ever.** Only metadata the pane already shows. A keystroke
  that quietly copied the first kilobyte of the selection would be an
  exfiltration primitive wearing a helpful face.
- **no provenance attributes.** `kMDItemWhereFroms` holds the URL a file was
  downloaded from and `com.apple.quarantine` holds who downloaded it and when.
  Both are ordinary extended attributes and both are browsing history. Attribute
  *names* are listed, since they describe the file; their values are not -- and
  the prompt says how many were withheld, so an edited list does not read as a
  complete one.
- **abbreviated paths.** A full path carries the account name, and often a
  client's or an employer's in a project folder. Anything under the home folder
  is written with a leading `~`, which keeps the shape and leaves you out of it.

And one that runs the other way. A file can be called anything, and a downloaded
one was named by someone else: `Ignore previous instructions and ....txt` is a
perfectly legal filename. Since this text is written to be pasted into a model,
every name sits inside a fenced block and the prompt states that the block is
data rather than instruction. That is not a guarantee -- no such wording is --
but omitting it would hand an attacker the instruction channel for nothing.

**Names are sanitised before they go in.** Wording alone does not survive a name
that is not what it looks like, and a file name is attacker-controlled text about
to be pasted into a model *and* drawn in a terminal:

| In a name | What it does |
| --- | --- |
| a newline | ends the `- name:` line, so the rest poses as metadata of its own -- an injection into *this* format, before any model is involved |
| `\r`, `\b`, `\a` | overwrite what is already drawn, so a terminal shows something other than what is there |
| ANSI escapes | move the cursor, recolour, and in some terminals reach the clipboard |
| U+202E and friends | the Trojan Source trick: reverses displayed order without changing a byte -- `invoice⁧fdp.exe` reads as `invoice.pdf` |
| U+200B, U+E0000-E007F | zero-width and tag characters, which render as *nothing* and are the usual way instructions are smuggled past a human reader into a model |
| ``` ``` ``` | closes the data block, escaping the fence that was the defence |

Each becomes a visible, inert `\u{XXXX}`. Backslashes are escaped first, so a
file literally named `\u{202E}` cannot be confused with one that was escaped.
Tags and symlink targets get the same treatment -- a tag was typed by whoever had
the file and a target written by whoever made the link, and neither is more
trustworthy than a name.

When anything is escaped, **both** parties are told: the status line says which
kind was found, and the prompt itself carries a note, because whoever reads the
model's answer needs to know the names were not as they appeared.

## Diptych instead of Finder

Settings ▸ Behaviour ▸ **Show files in Diptych instead of Finder** makes
other apps' *Show in Finder* and *Reveal in Finder* open the folder in Diptych,
with the file selected. It sets macOS's `NSFileViewer` default, the same
undocumented setting ForkLift and Path Finder use:

```sh
defaults write -g NSFileViewer -string dev.verhas.Diptych   # on
defaults delete -g NSFileViewer                             # off
```

Diptych runs exactly that, and remembers the choice: if the setting is found
missing at launch, it is put back. Switching it off removes it only while it
still names Diptych, so another app chosen since is left alone. Limits that
come with the setting, not with Diptych: an app reads it when it starts, so
apps already open keep using Finder until reopened; apps that tell Finder
directly by name, and Finder's own features, are not affected; and being
undocumented, a macOS update could change it.

The setting holds Diptych's bundle id, not a path: macOS asks LaunchServices
for an app with that id, which may be any copy of Diptych it has seen -- in
`/Applications`, an Xcode build, a mounted disk image. **Uninstalling without
switching it off does no harm**: when no copy of Diptych can be found, macOS
falls back to Finder (tried on macOS 27). `defaults delete -g NSFileViewer`
clears the leftover setting.

Diptych answers both requests it may be sent -- Finder's *reveal* and the
ordinary *open* -- in the frontmost window's active pane: a folder is opened,
a file is shown selected in its folder. A request that launches Diptych waits
for the first window.

## Local agent access (MCP)

F1 is a one-shot formatter: it describes the selection once and puts that on
the clipboard. This is the live counterpart -- while Diptych is running, it can
answer an agent's questions about what is actually on screen right now, and act
back into the GUI. It is **off by default**, same reasoning as version
tracking: it opens a local network listener Diptych did not need before, so
switching it on is a decision you make, not one made for you.

**Turning it on:** Settings ▸ Agents ▸ *Allow a local AI agent to query
Diptych*, open the agent terminal (below), or run **File ▸ Add Diptych to Agent Config (.mcp.json)…**,
which switches the server on for you and writes an entry into `.mcp.json` in
the active pane's directory:

```json
{
  "mcpServers": {
    "diptych": {
      "type": "http",
      "url": "http://127.0.0.1:8787/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

That write **merges**, it never overwrites -- any other server already
configured in that `.mcp.json` survives untouched. An agent CLI (Claude Code,
Codex, ...) started in that directory picks the entry up automatically.

**What it listens on:** `127.0.0.1` only, on the port shown in Settings. Every
request needs the bearer token; there is no bind-address or access-scope
configurability yet -- localhost is the only option.

**The token** lives in `~/.diptych/.mcp.token`, not in `config.json` --
config.json is meant to be readable and hand-editable, which is exactly what a
credential should not be. The file is set owner-read-only immediately after
every write. Settings ▸ Agents shows the current token (for pasting
somewhere by hand) and a **Regenerate** button, which writes a fresh one and
pushes it to the running server immediately -- the old one stops working at
once, not the next time the server happens to restart. Regenerating means
re-running **Add Diptych to Agent Config** (or hand-editing `.mcp.json`) and
reconnecting whatever agent was already using the old token.

**The status light.** While the server is on, a small dot sits in the
toolbar. It is dim when idle and pulses green on every call an agent makes --
red when a request is rejected for a missing or wrong token. Clicking it opens
**MCP Activity**, a log of every call with its arguments and every rejected
request, so what an agent did in the window you are looking at is never a
mystery.

**One Diptych at a time.** A second launch brings the running one forward
and quits, rather than the two quietly coexisting. Tool calls that name no
window go to "the" Diptych, which only means something if there is one.

**What it can see and do**, right now:

| Tool | Does |
| --- | --- |
| `list_windows` | Every open window: browser windows with each pane's directory and active side, plus Info / Compare / Bin Edit / Text Edit / Rename Many / Settings windows with what each is showing |
| `get_pane` | A pane's current directory and listing |
| `get_selection` | The files currently selected in a pane |
| `get_text_diff` | What an open Compare (file diff) window is comparing, whether it's a byte comparison, which side (if any) is unlocked for editing, and whether it has unsaved edits |
| `get_directory_diff` | What an open Compare Folders window is comparing: the two roots, the options results on screen were actually produced with, and the rename pairs diptych's own content-matching found |
| `select_items` | Replaces a pane's selection with given paths, visibly, in the GUI |
| `set_active_pane` | Makes a window's left or right pane the focused one |
| `open_diff` | Opens a Compare or Compare Folders window on two explicit paths; for two folders, the comparison options (permissions, ACL, attributes, dates, ownership, hidden recursion) can be set explicitly, and for two files, so can `ignoreWhitespace`/`wraps` -- reopening a pair already open updates that window instead of refusing |
| `open_info_window` | Opens the Info window for one explicit path |
| `list_settings` | A curated, scalar subset of Settings an agent can read: version tracking, scripts, Apple Intelligence, startup tips, sounds, sort order, name suggestion style, Compare Folders defaults, the update-check preference, and more -- not layout things (columns, toolbar, favourites) or MCP's own enable/port |
| `set_setting` | Changes one setting by key, from `list_settings` |
| `close_window` | Closes a window by the number `list_windows` reports, running the same unsaved-changes prompt `⌘W` would |
| `propose_file_operations` | Proposes a batch of file operations for you to review before anything happens -- see below. Returns as soon as the review window is open |
| `get_diptych_info` | The running Diptych: process id and start time, version and build, app path, debug or not, macOS version, MCP port, and runs started by this process against all kept |
| `list_runs` | The kept runs (Run ▸), counted back from the latest -- 1 is the last run; `from`/`to` choose a range, 1-10 by default: run id, command line, folder, running / finished / failed / stopped / interrupted, exit code, start, timing (`real`, `user`, `sys`), whether its tab is open, and which tab is in front (`focused`). Starting a run is deliberately not offered |
| `get_run_output` | What a run printed, as plain text without the terminal's colours, with its state and timing -- also after its tab is closed; the last 400 lines by default, up to 5000 -- so "why did that build fail?" needs no copy and paste |
| `get_batch_status` | Where a proposed batch stands -- reviewing, executing, finished or cancelled -- and, once it has run, each row's outcome and whether it failed |

None of these read or write file *contents*, and none return diff content
either -- deliberately: a shell already does `diff`/`cmp` better than an MCP
round-trip could, once it knows the two paths, which is exactly what
`get_text_diff`/`get_directory_diff` supply. The value is everything a
terminal has no way to see: what is selected, what a pane is browsing, what
window is open showing what and with which options, whether an edit is
unsaved, plus diptych's own rename-detection -- and being able to act back
into the window the person is actually looking at.

### The agent terminal

**View ▸ Show Agent Terminal** (`` ⌃` ``) opens a terminal under the whole
window, sidebar included, with your agent already running in it and Diptych
already in its configuration -- for talking to an agent about the files you
are looking at, in plain language, without setting anything up.

- **It starts in `~/.diptych/agentic`**, not in your files. Where the agent
  stands does not matter: it reaches files through Diptych. Each time a
  terminal starts, Diptych switches agent access on and writes three files
  there: `.mcp.json` with the current port and token, **`AGENTS.md`** -- the
  agent's instructions: change files only by proposing them to Diptych, never
  with the shell; reading is fine; scratch files go in `$TMPDIR`; what "this"
  and "the other side" mean -- and a `CLAUDE.md` that imports it, since Claude
  Code reads only that. Delete the first line of either instruction file and
  Diptych leaves it alone from then on.
- **The agent is configurable** in Settings ▸ Agents: the command (`claude` by
  default; `codex`, `copilot`, anything, with options; empty for a plain
  shell) and the folder. It is typed into your login shell, so your `PATH`
  and start-up files apply once, and when the agent exits the shell stays.
- **Its look is its own** -- font, size, and colours that follow the system,
  stay light or dark, or are chosen -- in Settings ▸ Appearance. Option types
  what your keyboard layout puts on it (`#`, `@`, `\`…), as in Terminal.app;
  *Use Option as Meta key* there makes it the shell's Meta instead.
- **A thin strip along the bottom of every window is its handle.** The
  terminal starts out closed, as just that strip; clicking it does what
  `` ⌃` `` does -- the first time it starts the agent, after that it folds the
  terminal back down to the strip, with everything still running, and opens
  it again. Drag the handle of an open terminal to resize it; the height is
  remembered.
- **Drop files on it** from a pane or Finder to type their paths, quoted for
  the shell.
- While it has the keyboard, Diptych's own keys stand aside: Tab completes,
  Return runs, ⌘C and ⌘V copy and paste text. ⌘⌫ deletes back to the start of
  the line, ⌘← and ⌘→ go to its start and end -- as in Ghostty and iTerm.
- **Selecting is copying**, in the agent terminal and in every run: let go of
  the mouse on a selection -- dragged, double- or triple-clicked -- and the text
  is on the clipboard and the selection cleared, without the padding at the
  ends of the lines. ⌘C does nothing in a terminal: pressed from habit it
  would otherwise replace what selecting just copied. A click into the
  terminal gives it the keyboard, so ⌘V pastes there, not into a pane. Hiding it (`` ⌃` `` again)
  keeps it running; `exit` closes it; quitting Diptych ends it.

### Batch file operations, reviewed first

The one exception to "no file operations": an agent can **propose** them, and
nothing happens until you have seen the whole list. "Move the archives to the
other folder, read-only" is safe to ask in one sentence because what the agent
understood appears in a window, and the one file it should not have included
gets unticked *before* it is touched.

The operations are move, copy, rename, move to Trash, permanent delete,
permissions, owner/group, symbolic link, new folder, **extended attributes**
(set one, in text, hex or base64, or remove one) and **Finder tags** (add,
remove, or set the whole list). In the review window:

- **Every row is ticked**, and can be unticked -- one at a time, a run of them
  with Shift-click, or all at once with Select All / Select None.
- **Every row is editable**: a destination path, a new name, an owner and group
  from a list, or the permissions in the same rwx grid the panes use. A
  permission row shows what the item has now next to what it will get; set the
  grid back to what it already is and the row dims and says **No change**,
  still ticked, and running it does nothing.
- **The batch is checked as a whole** before Execute is possible: two
  operations landing on the same path, or operations that depend on each other
  in a cycle, are reported and block it. Rows run in the order listed, except
  that a row working on an item another row produces -- renaming a file a
  move has just put in place, say -- waits for that row, and is skipped if
  that row failed.
- **Anything that overwrites an existing item, and any permanent delete, has a
  tick of its own** -- *Overwrite existing item* or *Delete permanently* --
  and Execute stays off until each is ticked or the row is deselected. The tick
  is for that one path: edit the row to point somewhere else and it has to be
  given again. A read-only item is not overwritten even then.
- **More than ten operations** are confirmed once more before running.
- **Owner changes that need an administrator** are collected and done together
  after one password prompt, however many there are.
- **Attribute and tag rows show what the item has now beside what it will
  have**: an attribute's value as text, a property list or a hex dump; tags as
  coloured chips, the row's own tags removable with their × and added from a
  field. Well-known attributes say what they are -- removing
  `com.apple.quarantine` says it skips the Gatekeeper check of a download.
  Tags are added to, or removed from, what the item has *when the batch runs*,
  and Finder's label colour is kept in step with them. A row that would change
  nothing says **No change**. Every attribute change is read back afterwards:
  macOS accepts some changes and ignores them -- `com.apple.provenance`, its
  own record of which tracked app made a file, cannot be removed by any
  program -- and such a row is reported as failed, not as done. Proposing to
  remove that one is flagged before anything runs. Its value is shown as its
  provenance ID and the installed apps that carry the same tag; in Get Info ▸
  Attributes, **Identify App…** names the app exactly -- path, bundle id,
  team, and since when macOS has tracked it -- from macOS's provenance
  database (`/var/db/SystemPolicyConfiguration/ExecPolicy`, readable only by
  root, so it asks for the administrator password once, reads it read-only,
  and remembers the answer for the session).
- **Read-only items are settled with one question** for the whole batch, not
  one per file: make the ones you own writable for the moment the change takes
  and restore their permissions straight afterwards, authenticate once as an
  administrator for all of them, or skip them.
- **Cancel closes the window** and changes nothing.

Each row then says what happened to it, failures in red, and the footer
counts successes and failures. What was done goes on the undo list, one step
per kind of operation -- the undo list cannot hold a move and a permission
change as one step. Attribute and tag changes undo by putting back the exact
bytes each attribute held before.

The design document this was built from, `DIPTYCH_MCP_PROPOSAL.md` -- the
reasoning behind what is and is not exposed -- is in the git history and in
the 1.4.x source archives; it is no longer kept up to date. Not built yet:
bind-address configurability.

## Copying, with progress

A copy to a slow disk used to be invisible: a sound at the end and nothing in
between. Now, if it outlives **one second**, a panel appears in the corner of the
window with the file being copied, a bar, bytes done of bytes total, a rough
estimate once there is enough to extrapolate from, and a **Cancel** button. Under
a second nothing appears at all -- a panel that flashes up and vanishes is worse
than none.

**The copy is `copyfile(3)`, not `FileManager.copyItem`.** Foundation's copy is a
black box that returns when it is done: four gigabytes to a USB disk is minutes
inside it with no way to report progress and no way to stop. `copyfile` calls
back as it goes and takes `COPYFILE_QUIT` for an answer -- while still carrying
metadata, extended attributes and ACLs, which a hand-rolled read/write loop would
silently drop. Progress is therefore **per byte**, not per file, which is the
only granularity that helps when the transfer is one large file.

A subtlety that cost a real bug: returning `COPYFILE_CONTINUE` from an *error*
stage tells copyfile to carry on, and the whole call then reports success. A
refused overwrite, a permission hole part-way through a tree, or a full disk
would all have been swallowed and announced as a completed copy. The callback
quits on error, and there is a test for it.

Progress updates are throttled to ten a second on the copying thread. Reporting
every callback would hop to the main actor thousands of times for one large file
and cost more than the copying.

**A move within one volume is a rename** -- instant, nothing to report and
nothing to cancel -- so it skips all of this. Across volumes a move is a copy
followed by a delete, and the delete only happens once the copy is known to have
worked.

**Cancelling asks what to do with what already arrived.** Whole items that
finished are real files; a half-copied one is removed by the copy itself.
Whether to keep the finished ones is a judgement -- a partly copied folder may be
worth keeping or may be clutter -- so it is asked rather than decided. Removing
them deletes them outright rather than via the Trash: they were made moments ago
by an operation you stopped, and putting them in the Trash would mean deleting
them twice.

**Transfers run one at a time**, because they share the clash dialog's
continuation -- a second one started while that dialog is open would strand the
first for ever. Serialised is not the same as ignored, though: asking for
another transfer while one runs now says so at once, and the panel carries an
"N more waiting" line. Before that it looked exactly like nothing happening,
until the second operation began minutes later of its own accord.

The panes are reloaded **and awaited** at the end of each transfer, not fired and
forgotten. The next transfer in the chain starts the moment the previous one
returns, and an un-awaited reload was queued behind it -- so a moved item sat
visibly in the source pane until an unrelated copy had finished.

The panel is an **overlay**, not a sheet. Only one presentation modifier per view
is reliable here, a clash dialog has to be able to appear *during* a transfer,
and an overlay leaves the panes visible while you watch.

## Drag and drop

Drag rows between the panes, out to Finder or any app that takes files, and
between separate Diptych windows -- all the same mechanism, since what leaves
the pane is a real file reference rather than a URL string.

The drop rule follows Finder: within one volume a drag **moves**, across volumes
it **copies**. Hold `⌥` to force a copy, `⌘` to force a move. Dropping items back
into the folder they already live in does nothing.

SwiftUI's URL importer hands over only the *first* item of a multi-item drag, so
the dropped files are read from the drag pasteboard directly instead. The drop is
handled by a `DropDelegate` rather than `.dropDestination`, because only a
delegate can advertise *move* -- `.dropDestination` always shows the copy badge,
even when the drop moves.

The whole pane area is one drop destination, and the target pane is worked out
from where the pointer is. SwiftUI gives every `.dropDestination` a platform view
the size of the entire window, so one per pane overlaps and whichever sits on top
swallows every drop.

Dragging is declared on the table *row*, never on a cell. A drag gesture inside
a cell competes with the table's own click handling, which is the same mistake
that broke row selection three times over.

## What a transfer will not do

Copy and move refuse a few things outright, because each of them destroys data
if allowed through:

- **Onto itself.** Copying into the folder an item already lives in makes a copy
  beside it, as Finder does; moving there does nothing. Neither raises a clash
  dialog, whose Replace would delete the target -- which is also the source.
- **Into its own descendant.** Foundation will recurse a directory into a copy
  of itself until the path is too long to extend.
- **A name that is not a name.** Typed names are appended as path components, so
  `../escaped` would otherwise create or move the item a level up. Rename, New
  Folder and "keep both" all go through one check that rejects separators and
  `.`/`..`, and confirms the result is a direct child.

**Replacing is staged.** The new item is copied beside the old one and swapped in
with `replaceItemAt`, so a failure part-way leaves the existing item intact.
Removing the destination first -- the obvious implementation -- loses it for good
when the copy then fails on a full disk or a disconnected volume. A failed copy
cleans up whatever it created rather than leaving a partial item behind.

**Transfers are serialised.** They share one conflict continuation, so a second
operation started while a clash dialog is open would otherwise overwrite it,
stranding the first for ever or answering the wrong one.

## Name clashes

A copy or move onto an existing name asks, rather than quietly inventing a new
one. Three mutually exclusive choices, as radio options:

- **Replace the existing item**
- **Keep both, naming the new item:** with the name field nested underneath,
  pre-filled with `name-1.ext`
- **Skip this item**

plus **Apply to all N remaining items**, which turns any of the three into
Replace All, Rename All or Skip All. **Abort** stops the whole operation. Both
appear only when items remain behind the current one.

The field sits *inside* the option it belongs to rather than above a row of
verbs: a value and a set of verbs side by side imply a relationship that is not
there, and Overwrite next to a name box reads as "overwrite, using this name".

Under Apply to all, a name you typed applies to the current item only; later
ones get automatic names, since one name cannot serve several files.

Rename and "rename to something I type" are one control: the text field starts at
the automatic suggestion, so pressing Rename untouched gives `notes-1.txt`, and
editing it renames to anything. Generated names count from 1 and join with a
dash, never a space.

Every copy and move goes through this one path -- F5/F6, paste, and drops alike.
Whatever lands is left selected in the destination pane.

## Copying to the pasteboard

`⌘C` / `⌘X` / `⌘V` put file URLs on the system pasteboard and paste them into the
active pane, so they interoperate with Finder in both directions. macOS has no
"cut" state for files, so the URLs go on the pasteboard exactly as a copy would
and the move intent is remembered against the pasteboard's change count -- if
anything else writes to the pasteboard, the cut lapses and a paste copies.

Right-click **Copy** does the same as `⌘C`; its submenu copies *text* instead:

- **File Name** -- the selected names (`⌥⌘C`)
- **Full Path** -- the selected paths (`⇧⌥⌘C`)
- **Content** -- what is in the file (`⌃⌘C`, or Edit ▸ Copy Contents): a text
  file as text, a picture or PDF as itself. Several text files are copied one
  after another. Offered only where it can work: a folder, an archive or any
  other binary file, or more than 32 MB, leaves it out of both menus. It is the
  way back from **New from Clipboard**.

For names and paths the items are space separated and quoted only where a shell
needs it, for pasting straight into a terminal as arguments:

```
-leading-dash.txt no-extension 'file with spaces.txt' 'dollar$sign.txt' 'quote'\''apostrophe.txt'
```

One thing quoting cannot fix: a name starting with `-` will be read as an option
by whatever command you paste it into. Put `--` before the list.

## The Info window

`⌘I` opens a window describing one file, keyed by URL so a second file opens a
second window. Five tabs, each applying on its own -- there is no global Save,
because the operations behind them are separate syscalls that fail
independently and a half-applied Save is worse than none.

| Tab | Holds |
| --- | --- |
| General | location (read-only), name (rename in place), kind, size, and the created / modified dates, which are editable. "Added" and "Accessed" are shown but not settable -- the first belongs to the folder's index, the second to the kernel |
| Ownership | owner and group pickers (for a symlink these are the *target's*, since that is what changing them affects), the setuid/setgid/sticky checkboxes, and the nine permission bits as checkboxes with the octal mode |
| Tags | the seven colours Finder gives a dot, plus free-form tags |
| Attributes | every extended attribute -- what `xattr` shows. Text values are editable, binary ones (plists, bookmarks) are shown as hex and can only be removed, since saving them as text would corrupt them |
| Access | the access control list as text -- the same form `ls -le` prints and `acl_from_text` accepts. Empty it to remove the list |

An ACL entry overrides the permission bits, and entries match top to bottom with
the first match winning -- so a `deny` above an `allow` wins even for the owner.
Renaming needs `delete`, because it removes the old name. When an operation
fails on an item that has an ACL, the error says so rather than leaving you to
wonder why `rwx` was not enough.

Tags are written straight to `com.apple.metadata:_kMDItemUserTags` as Finder
stores them (`"Red\n6"`), because `URLResourceValues.tagNames` has a setter only
on macOS 26 while the getter works everywhere.

They are also written to the pre-10.9 label bits in `com.apple.FinderInfo`.
Some volumes keep a colour *only* there -- a folder on an external disk can show
grey with no `_kMDItemUserTags` attribute at all -- so rewriting just the modern
attribute would leave that colour untouched and the tag apparently unremovable.

### Folder icons

macOS 26 draws folders tinted and carrying a symbol -- what Finder calls
*Customize Folder*. It takes three separate pieces, and all three have to agree
or the folder stays plain blue:

| Piece | Where |
| --- | --- |
| the **colour** | the Finder tag. There is no colour setting of its own |
| the **symbol** | an SF Symbol name in `com.apple.icon.folder#S`, as JSON: `{"sym":"eyebrow"}` |
| the **switch** | `kHasCustomIcon`, bit 10 of the Finder flags in `com.apple.FinderInfo` |

Which is why tagging a folder red does *nothing* to its icon on its own -- the
tag shows as a dot beside the name and the folder stays blue. Verified by
measurement: `NSWorkspace.icon(forFile:)` returns byte-identical images for a
plain folder and a red-tagged one, and a different image the moment the
custom-icon flag goes on.

The Info window's Tags tab has the control, next to the colours because the
colour *is* the tag: a switch for the tinted icon and a **searchable grid of
symbols**, since knowing that the one you want is called `eyebrow` is not a
reasonable thing to ask. SF Symbols has thousands of names and no API that lists
them, so `SymbolCatalog` is a hand-picked set of about 160 in nine categories,
each one checked against the running system at startup -- a name from a later SF
Symbols release renders as nothing at all rather than failing, and an invisible
cell in a picker is worse than a missing one. The search field falls through to
the live symbol lookup, so a name typed in full works even when it is not in the
catalogue: the list is a convenience, never a limit.

The `#S` on the attribute name is part of the name -- it marks the attribute
syncable, and macOS ignores the attribute without it.

`IconCache` keys directories **by path**, precisely because a folder can carry a
custom icon -- which made it the one thing still showing the old icon after a
change. Untinting a folder left it coloured until the next launch. The cache is
now told to forget the item whenever an Info window reports a change; reloading
the pane alone just redraws the same stale image.

`FinderInfo` owns the flag word, because the tag colour (bits 1-3) and the
custom-icon flag (bit 10) live in the same 16-bit field: writing one by hand
would clear the other, and there is a test for exactly that.

Every change reloads all five tabs, since they overlap: adding a tag rewrites an
extended attribute, and removing that attribute clears the tags. Each change also
posts a notification the panes listen for -- a directory watch reports entries
appearing and vanishing, never a chmod, so without it the pane kept showing the
old owner or mode until you navigated away and back. The toolbar has a Refresh
button too.

### When the file will not have it

`setxattr` on a file you may not write fails with `EACCES`, and for a long time
Diptych reported that only in the status line: you typed an attribute, pressed
Add, and nothing appeared. A change that silently does not happen is worse than
one that fails loudly, so every metadata change -- tags, attributes, access
control lists -- now goes through one ladder:

1. **It is reported.** A refusal raises an alert naming the change and the
   reason, never a quiet no-op.
2. **Diptych offers to unlock the item, apply the change and lock it again.**
   The app does this itself rather than telling you to go and change the
   permissions first: the item is unprotected for the microseconds the write
   takes instead of for as long as you remember to come back, and the app cannot
   forget to put the permissions back. The restore runs on the failing path too,
   and if it ever fails the status line says so in as many words.
3. **Failing that, it offers to authenticate.** Only the owner may `chmod`, so
   step 2 is not offered for someone else's file. Root needs no permission bits
   raised at all -- it bypasses the check -- so the escalated path performs the
   change directly, through `xattr(1)` or `chmod(1)`, in a single command.

That is why every change is described twice in the code: `apply` is the syscall
we make ourselves, `command` is the equivalent for step 3. Attribute values
travel as hex so a binary property list survives the shell, and an ACL that
cannot be translated into `chmod -E` syntax (a principal whose name contains a
space) offers no escalation rather than risk applying an entry to the wrong
principal.

## Details — what a file says about itself

The Info window's **Details** tab reads the attributes kept *inside* the file:

* **Pictures** — pixel size, resolution, colour model, orientation, and every
  dictionary ImageIO offers: EXIF, TIFF, IPTC, PNG, GIF, HEIC, and **GPS**, so a
  photograph's location is visible rather than merely present.
* **PDF** — page count, the first page's size in points and millimetres, the PDF
  version, whether it is encrypted, whether printing and copying are allowed,
  and the document's own title, author, producer and dates.
* **Sound and film** — length, picture size, frame rate, the four-character
  format codes, sample rate and channels per track, and the common metadata
  written into the file.
* **Everything else** — what Spotlight already knows: kind, title, authors,
  page count, languages, where the file came from. That covers Word,
  spreadsheets and presentations without unzipping anything, and it answers
  nothing on an unindexed volume, which the tab says rather than implying the
  file has no attributes.

**Read only, deliberately.** Every one of these formats keeps its metadata
inside the file, so changing a field means rewriting the file — re-encoding a
JPEG, or unzipping and rezipping an Office document. A file manager that
quietly re-encodes a photograph to fix a typo in a date has done more damage
than the typo. The tab says so at the bottom.

Values are made readable rather than shown raw: `ISOSpeedRatings` reads as *ISO
speed ratings* (a run of capitals is an abbreviation and stays whole), booleans
as Yes and No, dates in the local format, lists joined. Binary values — an EXIF
maker note is kilobytes of it — and anything longer than 300 characters are
left out. Reading is asked for when the tab is first opened, off the main
thread, and gives up after five seconds, since a film's tracks can reach for
the file itself.

Seventh tab, so the window's minimum width is 880: at 620 macOS folded the
whole tab bar into a "more toolbar items" pop-up where no tab could be chosen.

## Open By — what has a file open

The Info window's sixth tab lists the programs that have the file open, and for
a folder, what is open **inside** it plus any program whose current folder it
is — which is what actually stops a folder being moved or trashed.

Through **libproc** (`proc_listallpids`, `proc_pidinfo`, `proc_pidfdinfo`),
which is what `lsof` itself calls: `nm -u /usr/sbin/lsof` shows exactly those
symbols. No subprocess, no output to parse, and nothing that can hang on a
stale network mount, because it asks the kernel about processes rather than
walking the file system. Each holder shows the program, its process number,
whether the file is open for **writing** (listed first, in orange) or only for
reading, and for a folder which file it is.

Two limits, neither of them Diptych's to lift, both said on screen:

* **Other users' programs cannot be looked inside.** That needs root, and Full
  Disk Access does not change it. The footer gives all three numbers — "218 of
  284 programs could be looked inside. 66 belong to other users…" — so the
  answer reads as *your* programs, never as "nobody has it open".
* **Open is not locked.** Most programs holding a file open are only reading
  it. Advisory locks are a different mechanism whose holders cannot be listed
  at all, and the user-immutable flag is a third thing again.

It is asked for, not watched: a program can open or close a file between two
blinks, so the answer carries the time it was taken and a **Look Again**
button, and it is only asked when the tab is first shown. The search is bounded
by a three-second deadline and by 200 holders, and says when either cut it
short. The structures come from `<sys/proc_info.h>`, which ships in the SDK but
belongs to the kernel, so every call checks its own return value and anything
unreadable is left out rather than reported as an error.

Sixth tab, so the window's minimum width went from 520 to 780: at 620 macOS put
the **whole tab bar** into a "more toolbar items" pop-up, the same trap the
Settings window fell into when it gained a tab. Verified through accessibility:
six tab buttons in the bar, not one pop-up.

## Changing owner and group

Click the Owner or Group cell of an already-selected row (or use the Files
menu). A list appears; the choice applies to the whole selection.

For groups, the ones you belong to are listed first, because those are the only
ones a plain `chgrp` accepts.

Changing an **owner** is different: the kernel refuses it for everyone but root,
so a direct attempt always fails with EPERM. Diptych tries directly first, and
when that fails offers to redo it through the system's authentication prompt --
`chown` run as root, with the paths shell-quoted.

## Menu shortcuts and text fields

A menu key equivalent is matched *before* the responder chain, so any shortcut
that is also a text-editing binding will fire the menu command while you are
typing. Every such shortcut hands off to the focused editor first:

| Shortcut | In a text field |
| --- | --- |
| `⌘X` `⌘C` `⌘V` `⌘A` | cut / copy / paste / select all |
| `⌘⌫` | delete to the beginning of the line -- *not* move the file to Trash |
| `⌘↑` `⌘↓` | move to start / end of the text -- *not* navigate |

The permissions grid counts as an editor for this purpose too: it is a plain
NSView rather than a text view, but a shortcut must not act on the file list
while it is open.

## Tests

```sh
./build.sh test
```

`DiptychTests/` covers the destructive paths, because those are the ones where a
bug costs someone their files: copying an item onto itself, replacing without a
fallback, recursing a folder into itself, typed names escaping their folder,
special permission bits surviving an edit, and navigation history.

The test target is wired into `project.pbxproj` with a synchronized folder
group, so a new file in `DiptychTests/` joins the suite without touching the
project.

## Releasing

```sh
./build.sh version    # print the version and build number
./build.sh version 1.0.1   # set it
./build.sh dmg        # Release build, packaged as build/Diptych-<version>.dmg
./build.sh notarize   # submit that image to Apple and staple the ticket
```

`dmg` builds Release, signs the app with the Developer ID certificate named
in `build.sh`, stages it next to a symlink to `/Applications`, and writes a
compressed image. Mount, drag across, eject -- the arrangement users expect.

The version comes from `MARKETING_VERSION` in the Xcode project, which is the
semantic version (`1.0.0`); `CURRENT_PROJECT_VERSION` is the build number and
may go up between releases of the same version.

**Signing and notarizing.** Without a Developer ID the image is unsigned and
macOS refuses to open the app on any machine but this one -- the user has to
right-click and Open, and is told the developer cannot be verified. To avoid
that you need the Apple Developer Program, a *Developer ID Application*
certificate in the keychain, and credentials stored once.

The certificate is chosen by its **SHA-1 hash**, `DEVELOPER_ID` at the top of
the signing section of `build.sh` -- never by its name, which has an accented
letter `codesign` mis-decodes, and which two certificates can share (an
expiring one and its replacement). A certificate that is not in the keychain
means an unsigned build, never another certificate quietly used instead. To
sign with a different one for a single run:
`DEVELOPER_ID=<hash> ./build.sh dmg`; `security find-identity -v -p
codesigning` lists the hashes. Developer ID certificates now expire, so this
changes when one is renewed.



```sh
xcrun notarytool store-credentials Diptych \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

The version lives in `Diptych.xcodeproj/project.pbxproj` as `MARKETING_VERSION`,
**twice** -- once per build configuration -- and there is no `Info.plist` to
edit: `GENERATE_INFOPLIST_FILE` is on, so Xcode synthesises one at build time.
`./build.sh version 1.0.1` writes both copies, so Debug and Release cannot drift
apart, and increments `CURRENT_PROJECT_VERSION` alongside -- that is the build
number, and Apple rejects a second upload that reuses one. The DMG filename and
the volume name follow from the built bundle, so nothing else needs editing.

Then `./build.sh dmg && ./build.sh notarize`. Stapling matters: it puts the
ticket inside the image, so the app opens even on a machine that is offline the
first time it runs.

## Running programs

A script or command-line tool -- any file you may execute that is not a folder
or an app -- has **Run ▸** in its right-click menu. Apps keep *Run App*.

- **Run with Arguments…** (`⌥↩`, also in the File menu) asks for the
  arguments on one line, pre-filled with the most recent ones; `↑` and `↓`
  step through the earlier ones, as at a prompt. The exact command and the
  folder it runs in are shown before anything runs.
- **Environment variables** for the program: a list of name and value pairs
  under the arguments, added with *Add Variable* and removed with ⊖. They are
  set with `env(1)` after your login shell has read its start-up files, so a
  `.zprofile` cannot override them, and they appear in the command shown --
  `CONFIG=Release ./build.sh dmg`. `↑` and `↓` bring back an earlier run's
  arguments and variables together; what was being edited is dropped.
- **Save as a template** keeps that arguments-and-variables set in the menu
  as a starting point: choosing it opens the window filled in instead of
  running at once, the template box unticked -- tick it to keep the edited
  version as a template of its own. Templates are never rolled off by the
  history limit.
- **Under it, the runs it was run with**, most recent first, marked **Ⓣ** for
  a template and **Ⓔ** when they set variables -- two entries can read the
  same and differ only in their variables. Choose one to run it again at once
  (a template opens the window); `⌥`-click one to delete it instead, with no
  undo -- the menu's last line says so.
- **It runs in the active pane's folder** -- usually the program's own. When
  you right-click a program while the *other* pane is active, the item says
  *Run with Arguments… in "that folder"*.
- **The arguments go to your login shell as typed**: quotes, `~`,
  `$VARIABLES`, wildcards and pipes work as at a prompt. The program's own
  path is quoted by Diptych.
- **Each run is a tab of one Runs window** -- whichever window it was
  started from -- so "the run in front" is always clear. A real terminal --
  colours,
  progress bars, and questions the program asks all work. Typing reaches the
  program while it runs; once it ends the window takes no input, and shows
  *Finished*, *Failed -- exit N* or *Stopped*, with the time it took as
  `time` reports it: `real`, and the `user` and `sys` time of the program and
  everything it ran. **Copy Output** copies all of
  it as plain text; **Stop** sends Control-C; **Run Again**; closing a window
  whose program is still running asks first.
- **A downloaded program** -- one with `com.apple.quarantine` -- is asked
  about before it runs: macOS checks downloaded apps, but no one checks
  downloaded scripts.
- **No agent can run anything.** Running a program is not offered over MCP --
  but an agent can *read* a run: `list_runs` and `get_run_output` let you ask
  "why did that fail?" without copying any output.

**Runs are kept for a while.** Each run's record (what ran, where, how it ended,
how long it took) and, once it exits, everything it printed are written to
`~/.diptych/runs/` -- private to you, since output can hold anything. Settings
▸ Behaviour ▸ *Keep runs and their output for* decides how long: an hour to 30
days, or until deleted; a day by default. They are purged at launch, whenever a
run starts and every quarter of an hour -- never one whose tab is open -- and
*Delete All Kept Runs* clears them at once. A closed tab's run is still there: MCP's `list_runs` lists
them counted back from the latest (1 is the last run, `from`/`to` choose a
range) and marks the tab in front as `focused`, and which Diptych process
started each one -- `thisSession`, or one before a restart; `get_run_output`
reads any of them. A run Diptych quit during is listed as *interrupted*.

**Tabs.** Every run is a tab of the one **Runs** window, whichever window
started it -- Diptych's own tab strip, not macOS window tabs, so there is no
*+* opening an empty window, a new run never appears on its own, and the tab in
front is unambiguously "this run". Each tab shows how it stands (blue running,
green finished, red failed, orange stopped) and has its ×; closing a tab, or the
window, that still runs something asks first. The tabs share the width; when
there are too many to fit, ‹ and › step through them, ⌄ lists them all, and the
tab shown is always scrolled into view.

**The history.** One JSON file per program in `~/.diptych/run-history/`,
named by the MD5 of the program's real path, with that path inside so `grep`
finds it -- not one file for every program, so hundreds of scripts cost
nothing. Settings ▸ Behaviour sets how many lines a program keeps (or
*Unlimited*); a program's own file can say otherwise, and can be opened from
*Run with Arguments… ▸ Edit History File…*:

```json
{
  "path" : "/Users/me/github/diptych/build.sh",
  "fixed" : true,
  "limit" : 5,
  "entries" : [ { "arguments" : "dmg", "lastRun" : "2026-10-04T17:12:00Z" } ]
}
```

Every file spells out `"fixed"`, `"limit"` and `"unlimited"`, so they can be
found by whoever opens it; the limit starts as the one in Settings and is the
program's own from then on. `"fixed": true` keeps the list exactly as written -- running never reorders,
adds or trims it; deleting still works, and saving a template, a deliberate
act, still adds one. An entry may carry `"environment"` (a list of `name` and
`value`) and `"template": true`. `"limit"` or `"unlimited": true`
overrides Settings for that program. Empty arguments are never recorded.

**The history follows the program.** It carries its key in the extended
attribute `dev.verhas.diptych.run-history`. Moved, it finds its history by the
attribute and takes it along; copied -- the original still there -- the copy
inherits the history once and then goes its own way. Nothing is written when a
menu opens, only when something runs. Where a volume keeps no attributes, a
moved program simply starts afresh.

## Scripts

| Script | Does |
| --- | --- |
| `./build.sh` | build / run / clean -- see above |
| `./build.sh test` | run the unit tests |
| `./make-testdata.sh` | wipes `test/` and rebuilds a playground: deep nesting, awkward names, symlinks (including a broken one), hidden files, executables, a bundle, a 240-file directory for scroll tests, files from 1 byte to 10 MB, and `test/acl/` where files and a folder carry real access control lists and editable extended attributes -- including `locked-by-acl.txt`, which an ACL `deny` makes impossible to rename or delete, `awkward names/read-only.txt`, a 444 file for the unlock-change-restore ladder, and `tinted folder/`, which carries all three pieces of a custom folder icon |
| `swift make-icon.swift` | redraws the app icon into `Diptych/Assets.xcassets` |

### The icon

Two hinged panels on navy, with an orange hinge in the gutter, drawn by
`make-icon.swift` at every size the Dock and the menu bar ask for. The panels
are large high-contrast blocks so they survive 16pt; the ruled lines standing in
for a file listing are allowed to disappear below 64.

In the bottom-right corner it wears the same **Swiss badge** as Tychedit — a red
rounded square with the flag's cross — in that icon's own geometry: the badge is
20.5% of the canvas, 14% in from the right and 15% up from the bottom, its
corners rounded by 8.6% of its width, and the cross to the flag's official
proportions, where the cross is 20 units long and its arms 6 thick in a field of
32. Below 32pt the badge is left out: the arms come to less than a pixel there
and it turns into a pink smudge, which signals nothing.

## Layout

```
Diptych/
  DiptychApp.swift          @main entry point, window, menu bar
  Model/
    FileItem.swift          one row: a struct, Sendable, value semantics
    DirectoryLoader.swift   actor -- reads directories off the main thread
    FileOperations.swift    actor -- copy / move / trash / mkdir / rename
    PaneModel.swift         @MainActor @Observable state of one pane
    AppModel.swift          both panes, active side, every command
  Views/
    PaneView.swift          path bar + Table + status line
    ContentView.swift       HSplitView, dialogs, function-key bar
  Support/
    Workspace.swift         NSWorkspace: open, reveal in Finder, icons
    KeyMonitor.swift        AppKit NSEvent monitor for the F-keys
```

The Xcode project uses a *synchronized folder group*: the `Diptych/` directory
is the target's source list. Add a `.swift` file anywhere under it and it is in
the build -- no need to touch `project.pbxproj`.

## Sandbox

`Diptych.entitlements` turns the App Sandbox **off**. A sandboxed app can only
see folders the user picked in an open panel (persisted as security-scoped
bookmarks), which is unworkable for a file manager. The cost is that this app
cannot ship on the Mac App Store. Grant it Full Disk Access under
*System Settings > Privacy & Security* to stop the per-folder consent prompts.

## Not done yet

- **First click when Diptych is not frontmost** selects nothing -- macOS spends
  it activating the app. Patching `acceptsFirstMouse` by re-classing SwiftUI's
  private table view crashed AppKit's derived-property system, so it was
  reverted; a local `.leftMouseDown` monitor is the safe route.
- **Progress and cancel for copy/move.** `FileManager.copyItem` reports no
  progress. Either wrap the call in an `NSProgress` via
  `becomeCurrent(withPendingUnitCount:)`, or write a chunked copy over
  `FileHandle` and report bytes yourself.
- **Quick Look on F3** via `QLPreviewPanel`, instead of opening the default app.
- **Drag and drop** between panes and with Finder: `.draggable` /
  `.dropDestination` with `UTType.fileURL`.
- **Per-pane tabs.** `⌘T` gives macOS window tabs -- a tab is a whole two-pane
  session. A macOS window tab is a whole window, so a tab here is a
  whole two-pane session. Tabs *inside* a pane -- what file managers usually
  mean -- would be an array of directories per `PaneModel` plus a `TabView`.
- **Type-ahead find**, bookmarks/favourites, remembering pane directories across
  launches (`@AppStorage`).
