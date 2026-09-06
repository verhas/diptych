# Diptych

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
| `⌘.` | show/hide hidden files |
| `⌘N` / `⌘T` | new window / new tab -- each with its own two panes, titled by folder |
| `Space` | Quick Look preview; arrow keys keep walking the listing and the preview follows. Space or Escape closes it. Files the system has no preview for (`.env`, `.gitconfig`, extension-less scripts) are shown as text when they sniff as text. F2 works with the preview open, so you can look at a scan and name it |
| `⌘C` `⌘X` `⌘V` | copy / cut / paste files, via the system pasteboard (works with Finder both ways) |
| `⌘[` `⌘]` | back / forward through the active pane's directory history |
| `⌘I` | Info window for the selected file (exactly one) |
| `⌘A` | select all -- in the path box it selects the text, otherwise every row |
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

## Sidebar

`⌃⌘S`, or the toolbar icon, shows a sidebar of **Volumes** and **Favourites**.
Clicking a row opens it in the active pane.

Drag any **folder** from a pane onto the sidebar to add a favourite -- files are
refused, since a favourite is somewhere to go. Drag a favourite up or down to
reorder it. Remove one with its context menu or `⌘⌫`. Volumes cannot be
reordered; their order belongs to the system. Favourites are global and live in `config.json`;
whether the sidebar is open is per window, in `state.json`.

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

**Hide** decides what happens to items that do not match:

- off (default) -- they stay listed but greyed out, cannot be selected, and the
  arrow keys step over them
- on -- they are not listed at all

`..` always matches; it is navigation, not content.

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
| `r` `w` `x` | set that bit **in the current group**, wherever the caret sits in it; the caret does not move |
| `⇧R` `⇧W` `⇧X` | clear that bit in the current group |
| `⌥R` `⌥W` `⌥X` | toggle that bit in the current group |
| `←` `→` | move one bit |
| `⇥` / `⇧⇥` | next / previous group -- the shortcut; the arrows stay bit-by-bit |
| `⌫` | step back one bit and clear it |
| `Home` `End` | first / last bit |
| `↩` / `Esc` | apply / abandon |

Two ways to reach any bit: arrow onto it and use `-`/`+`/Space, or address it by
letter from anywhere in its group with plain / `⇧` / `⌥`.

The caret's group is tinted and the caret bit highlighted, because the letters
act on the group while `-`, `+` and Space act on the single bit.

While editing, the column heading reads **user**, **group** or **other**
depending on where the caret is. The result is an absolute mode applied to every
selected item -- which is what makes editing several files at once well defined,
and is why permissions can be edited for a multiple selection where a name
cannot.

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
| Ownership | owner and group pickers, and the nine permission bits as checkboxes with the octal mode |
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

Every change reloads all five tabs, since they overlap: adding a tag rewrites an
extended attribute, and removing that attribute clears the tags. Each change also
posts a notification the panes listen for -- a directory watch reports entries
appearing and vanishing, never a chmod, so without it the pane kept showing the
old owner or mode until you navigated away and back. The toolbar has a Refresh
button too.

## Changing owner and group

Click the Owner or Group cell of an already-selected row (or use the Files
menu). A list appears; the choice applies to the whole selection.

For groups, the ones you belong to are listed first, because those are the only
ones a plain `chgrp` accepts.

Changing an **owner** is different: the kernel refuses it for everyone but root,
so a direct attempt always fails with EPERM. Diptych tries directly first, and
when that fails offers to redo it through the system's authentication prompt --
`chown` run as root, with the paths shell-quoted.

## Scripts

| Script | Does |
| --- | --- |
| `./build.sh` | build / run / clean -- see above |
| `./make-testdata.sh` | wipes `test/` and rebuilds a playground: deep nesting, awkward names, symlinks (including a broken one), hidden files, executables, a bundle, a 240-file directory for scroll tests, files from 1 byte to 10 MB, and `test/acl/` where files and a folder carry real access control lists and editable extended attributes -- including `locked-by-acl.txt`, which an ACL `deny` makes impossible to rename or delete |
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
