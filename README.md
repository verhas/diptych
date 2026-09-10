#  Diptych

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
| `⌘A` | select all -- in the path box it selects the text, otherwise every row |
| `⌃⌘V` | paste as a **symbolic link** to what was copied, rather than a copy of it |
| `⌥⌘C` / `⇧⌥⌘C` | copy the selected file names / full paths as shell arguments |
| `⌘U` | swap the left and right panes |
| `⌘⇧G` | go to folder -- a path that is not a folder is refused and the editor stays open; Escape returns to where you were |
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

**The filter** takes a shell pattern by default -- `*.txt`, matched by `fnmatch`,
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
says more than a list of number pairs. Keys it cannot name still show their
bytes. A file that fails to decode gets a page saying so, rather than falling
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

## Bin View

Right-click a file ▸ **Bin View** opens a hex editor in its own window, one per
file. The entry is absent for folders rather than greyed out -- it would be
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

**A refused send is not a dead end.** It almost always means someone else sent
something first, so the dialog offers **Get the Latest** -- with Git's own words
behind a disclosure triangle and a Copy Details button -- rather than handing
over a paragraph of Git and leaving the reader to work out what to do.

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

- **File Name** -- the selected names
- **Full Path** -- the selected paths

Either way the items are space separated and quoted only where a shell needs it,
for pasting straight into a terminal as arguments:

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

`dmg` builds Release, signs the app with a Developer ID certificate if the
keychain holds one, stages it next to a symlink to `/Applications`, and writes a
compressed image. Mount, drag across, eject -- the arrangement users expect.

The version comes from `MARKETING_VERSION` in the Xcode project, which is the
semantic version (`1.0.0`); `CURRENT_PROJECT_VERSION` is the build number and
may go up between releases of the same version.

**Signing and notarizing.** Without a Developer ID the image is unsigned and
macOS refuses to open the app on any machine but this one -- the user has to
right-click and Open, and is told the developer cannot be verified. To avoid
that you need the Apple Developer Program, a *Developer ID Application*
certificate in the keychain, and credentials stored once:

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

## Scripts

| Script | Does |
| --- | --- |
| `./build.sh` | build / run / clean -- see above |
| `./build.sh test` | run the unit tests |
| `./make-testdata.sh` | wipes `test/` and rebuilds a playground: deep nesting, awkward names, symlinks (including a broken one), hidden files, executables, a bundle, a 240-file directory for scroll tests, files from 1 byte to 10 MB, and `test/acl/` where files and a folder carry real access control lists and editable extended attributes -- including `locked-by-acl.txt`, which an ACL `deny` makes impossible to rename or delete, `awkward names/read-only.txt`, a 444 file for the unlock-change-restore ladder, and `tinted folder/`, which carries all three pieces of a custom folder icon |
| `swift make-icon.swift` | redraws the app icon into `Diptych/Assets.xcassets` |

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
