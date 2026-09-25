# Diptych 1.3.0

The headline is **Compare Folders**: a third kind of comparison, next to files
and bytes, for two whole directory trees. Selecting a file and a folder now
says so instead of guessing; selecting two folders opens a window of its own.
Everything else here is what came out of actually using it — a dozen small
fixes, most of them found by dogfooding the new window against real folders.

---

## Compare Folders

Select two folders — one in each pane, or two in the same one — and press
⌘D. Every file is paired with its match on the other side, or shown on its
own when it has none.

### Matched by name, or by content

A pair is made two ways: the same relative path on both sides, or — when a
file has no match by path — the same bytes as an unmatched file elsewhere.
The second is what a rename looks like after a folder is copied and a file
in it renamed: nothing shares its old name any more, but something shares
its bytes.

### What differs, in colour

Each row carries small coloured letter badges for exactly what sets the two
sides apart — **N**ame, **S**ize, **C**ontent, **P**ermissions, e**X**tended
attributes, **A**CL, **M**odified, **B**orn (created), **O**wner/group, or
**F** for a file matched against a folder. A legend at the foot of the
window spells all ten out, so the letters don't have to be memorised between
one comparison and the next.

Hovering a row's badges, or the row itself, says more: which side is newer
when a date differs (modification wins over creation when both do), and —
new, and worth having — **"Same content as: …"** underneath a file that
turns out not to be unique. A rename match only ever accounts for one
duplicate; if a folder copy left three files with identical bytes, all three
now say so, including the one that happened to be picked as the "official"
match. Empty files are left out of this entirely — every empty file matches
every other one, and saying so would say nothing.

### Choosing what to compare

Content is always compared — it's the one thing "the same" can't mean
without. Permissions, extended attributes, ACL, modification date, creation
date, and owner/group are each a checkbox, on the window and as a default in
Settings. Out of the box, a fresh install compares **content alone**, which
by way of the rename match means names too; the rest is there for when it
matters and quiet when it doesn't.

Owner, group, and access time were left out of the original plan and asked
for afterwards: owner and group are one checkbox, not two — nothing here
ever cared about a mismatched owner without also caring about the group —
and access time isn't offered at all, since comparing a file is itself a
read that would change it.

Change a checkbox after the comparison has run and a **Refresh** button
appears, styled to say which reason it's there for: filled in when a
checkbox is the reason, plain when it's just that the folders themselves
might have changed since.

Folders whose name starts with a dot — `.git` and the like — are listed but
not recursed into by default, on or off in Settings and on the window. Two
folders being compared that are *themselves* dot-folders are the exception:
comparing two `.git`s recurses into their own hidden subfolders by default,
since that's plainly the point of asking.

### Filtering the list

A filter box works exactly like a pane's own: plain text finds a fragment
anywhere in a name, a shell pattern with `*` or `?` still means what it
always did, and a checkbox reads it as a regular expression instead. Another
checkbox hides non-matching rows outright rather than dimming them. Two more
narrow the list on their own terms: **Only differences** drops anything
that's the same, and **Ignore missing** drops anything that exists on only
one side — independent of each other, since a file missing its partner
isn't "the same" either way.

Wide windows get **zebra striping** to lead the eye down the list, now that
the badges freed the row background from having to carry that on its own.

### Going further

- **⌘D** or a double-click on a matched pair of *folders* opens a comparison
  of its own, narrowed to just the two of them — the same window, for a
  closer look at one part of a larger tree.
- **⌘I** opens Get Info on whichever side or sides exist, to put xattrs, tags
  and ACL side by side and compare them by eye.
- **⌘G**, or the **Go to** button, sends the pair back to the Diptych tab
  the comparison was opened from: the left pane to the left file, the right
  pane to the right one, both selected, the left pane made active. With
  only one side present, only that pane moves, and becomes the active one.

---

## Comparing two files that aren't text

Already in place before folders arrived, and worth its own line: comparing
a pair where either side is binary used to open the text comparison window
anyway, warning in the middle with find, wrap, ignore-spacing and the
padlocks all still on show, none of them meaning anything without lines.

It now answers the one question worth asking: the files are exactly the
same, they differ from the very first byte, they differ but agree up to a
point — given in decimal and hex — or one is exactly the beginning of the
other. Read a megabyte at a time and stopped at the first difference, so two
disk images don't go into memory to settle what the first kilobyte usually
does.

---

## Everything else that is new

- **⌥Tab cycles Diptych's own windows** — the browser, and every Get Info,
  Compare, Bin Edit, Text Edit and Rename Many window open alongside it —
  in a fixed rotation, wrapping around. With only one window open it swaps
  that window's own panes instead, the way plain Tab does.
- **Tooltips appear sooner.** AppKit's own delay read as broken rather than
  deliberate on something meant to be skimmed one after another, like the
  comparison's letter badges.

---

## Fixes worth knowing about

- **A drag onto a folder inside a pane now lands inside it.** The single
  drop target covering both panes worked out *which pane* a drop was in by
  testing each table's full bounds — which, for a table with more rows or
  columns than fit on screen, reach past what's actually visible and into
  the other pane's half of the window. A drop meant for the right pane
  could match the left one first and answer "already in" the folder it came
  from. Dragging a file onto a folder now opens that folder after it's held
  there a moment — Finder's spring-loaded folders — with a longer pause
  before a *second* folder can open the same way, so a folder landing under
  a still pointer right where the first one's icon just was doesn't open in
  turn.
- **Reopening a comparison no longer shows what was on disk the first time
  only.** Closing a Compare or two-file comparison window and editing one of
  the files, then comparing the same pair again, kept showing the old
  content — a SwiftUI window can keep its state across being closed, and the
  load that ran once on first appearing never ran again. It now reloads
  every time the window appears.
- **The filter box lets go of the keyboard.** Typing in a Compare window's
  filter and then clicking a row left the field focused and blinking; a
  click anywhere in the list now moves the keyboard where the click was.
- **Text Edit accepts the first keystroke on an empty file.** Nothing had
  ever asked the text view to become first responder; a non-empty file
  happened to end up focused anyway, an empty one didn't, and the first
  keystroke rang the system bell instead of typing. The caret now lands at
  the end of whatever loaded, empty or not, and is ready for it.
- **Two stray items are gone from the Files menu.** macOS appends *Start
  Dictation* and *Emoji & Symbols* to any menu it recognises as an Edit
  menu, which the Cut/Copy/Paste group is enough to trigger — neither meant
  anything here, since nothing in Diptych is a text view they could act on.
- **The Info window's status line names the file, not just its folder.**
  Every tab but General hid the name the folder path was shown next to;
  with more than one Info window open there was nothing on screen saying
  which file a given one was about.

---

## Upgrading

Nothing to do. The new Compare Folders settings take their defaults: content
alone, nothing else, folders recursed as usual. Existing per-window
checkboxes on a Compare window you already have open follow whatever you
last set there.

New shortcuts: **⌥Tab** cycles windows; inside a Compare Folders window,
**⌘G** goes back to the tab it was opened from.

---

*728 tests.*
