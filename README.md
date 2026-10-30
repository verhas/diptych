#  Diptych

*Diptych — pronounced ‘deep tech’ — the agentic Swiss pocket knife of file managers for macOS.*

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
and exits non-zero. `build`, `run`, `release` and `dmg` first run
`make-places.sh` -- the towns list, from GeoNames -- when the version has
changed since it last ran, or a month has passed; without the network the
build goes on with the list already there.

Requires macOS 15+ and Xcode 26. Signed ad-hoc, so it runs locally without a
developer account.

## Keys

| Key | Action |
| --- | --- |
| `Tab` | switch active pane |
| `Return` | enter directory / open file |
| `F2`, or click the name of an already-selected row | rename in place (base name pre-selected, as in Finder). The click is switched off in Settings ▸ Behaviour by **Rename on a click on the name**; F2 always works |
| `F4`, `F9`, `⌥⌘P`, or click the permissions of an already-selected row | edit permissions in place, for the whole selection |
| click a date, or a picture's or video's value, in an already-selected row | edit it in place, for the whole selection -- see [Values edited in place](#values-edited-in-place) |
| `⇧↩` | while renaming: commit and move to the *next* row -- the one that followed this file before the rename, so you can name a run of files in sequence |
| `F4`, `F5`, `F6` while renaming | commit the name, then edit permissions, copy or move the file under its new name -- no second click needed |
| `F3` | view (opens in the default app) |
| `F5` | copy selection to the *other* pane |
| `F6` | move selection to the other pane (the moved files stay selected there) |
| `F7` | new folder |
| `F4` | edit permissions (also on the function bar) |
| `F8`, `⌫`, `⌦` | move to Trash, with confirmation; the cursor lands on the row that followed the deletion |
| `⌘⌫`, `⌘⌦` | move to Trash immediately, no confirmation |
| `⇧⌘↑` / `⇧⌘↓` | move the selected files a place up or down: an order of your own until a header is clicked or the folder left -- see [Sorting and links](#sorting-and-links) |
| `⌘=` | show the active pane's folder in the other pane |
| `⌘2` | one pane / two panes |
| `⇧⌘.` | show/hide hidden files (as in Finder; plain `⌘.` is the system's "cancel") |
| `⇧⌘F` | flat view: the active pane's folder and everything under it as one list, filtered by an expression -- see [Flat view](#flat-view) |
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

### Links to the folders above: hold Option

**Hold Option** with the mouse over the path bar, or while typing in it, and
the path turns into links, one per folder, like a web page:
`/ Users / verhasp / github`. Click one to go straight there -- several levels up
in one click, with the folder you came out of selected, as going up does. The
last name is where the pane already is, so it is not a link. Let Option go and
the text comes back; anything you had typed, and the selection, is still there.

While you type or paste a path, the links are **that path's** folders, not the
pane's: paste `/Users/verhasp/.diptych/filters/imagek.json`, press Option, and
click `filters` -- the folder, with the file selected. A path that does not
exist yet links as far as it does.

Option with Command or Control is a shortcut being typed, so it leaves the bar
alone.

## Sidebar

`⌃⌘S`, or the toolbar icon, shows a sidebar of **Volumes**, starred
**Servers** (see [File servers](#file-servers)) and **Favourites**.
Clicking a row opens it in the active pane.

The highlighted row is not stored: it is *derived* from where the active pane
actually is, and opening happens in that selection's setter. Stored selection
looks equivalent and is not. Click **github**, then go into **diptych**, then
click **github** again: the row was still highlighted, so the click assigned the
value already there, which is not a change, so nothing happened. Deriving it
means the row deselects as soon as you leave the folder, and clicking it is a
change again.

Drag any **folder** from a pane onto the sidebar to add a favourite -- plain
files are refused, since a favourite is somewhere to go. A **disk image** --
`.dmg`, `.iso`, `.cdr`, `.sparseimage` -- may be a favourite too: it is a file,
but opening it mounts it and shows its volume, so clicking the favourite mounts
the image (asking the password of an encrypted one) and goes to it, and ejecting
it from the sidebar is the usual eject. A favourite whose image has since moved
away says so rather than doing nothing. Drag a favourite up or down to
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

Each volume also carries a small **trash** button on the *left* of its row --
deliberately the opposite side from Eject, so a stray click opens the Trash
rather than ejecting the disk. It opens that volume's Trash in the active pane:
`~/.Trash` for the startup volume, `.Trashes/<uid>` for any other. A volume
grows its own `.Trashes/<uid>` only once something is trashed on it, so the
button says the Trash is empty rather than opening a folder that is not there.
Open Trash is on the volume's context menu too. See [Trash
listing](#trash-listing) for what the pane then shows.

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

## Trash listing

Open a volume's Trash from the sidebar (the trash button on the left of a
volume, or Open Trash in its menu) and the pane lists it like any other folder,
with one addition: an **Original Location** column, showing where each file was
before it was trashed. It is on by default, appears *only* in a Trash listing --
never in an ordinary folder -- and the path, often longer than the column,
truncates in the middle and shows in full on hover.

Because it is a Trash-only column, it is offered in the pane's **header
right-click menu only while that pane shows a Trash**, and switching it there --
or dragging it to another position -- has an effect only on Trash listings. (It
can also be switched in Settings ▸ Columns.) It is never offered or drawn in an
ordinary folder, which is both what the feature means and what keeps AppKit from
drawing a column that does not belong there.

A Trash listing's right-click menu is **trimmed** to what Finder's own Trash
menu offers: making and pasting files have no place in the Trash, so those are
not offered, but putting a file back, renaming it, looking at it and getting rid
of it for good are -- Put Back, Compare, Open, Get Info, Reveal in Finder,
Rename, Copy Name/Path, Delete Immediately and Empty Bin -- and on the empty
space Refresh and Empty Bin. The first two, for a file whose old place is known:

- **Put Back** moves it back where it came from, recreating the folder if it has
  gone and stepping past a name taken in the meantime rather than overwriting
  it.
- **Compare with the Original…** opens the ordinary comparison window with the
  trashed version on the left and whatever is at its old location now on the
  right -- offered only when something is there to compare with. A file in the
  Trash is nothing special to read, so this is done in place, with no copying
  back and forth.

The last two leave the Trash for good, and both ask first because neither can be
undone: **Delete Immediately** removes the selected items, and **Empty Bin**
clears the whole Trash the listing is showing. In a Trash listing the ordinary
trash keystrokes delete for good instead of trying to re-trash what is already
there: `⌫`/`⌦` and `⌘⌫`/`⌘⌦` both run Delete Immediately, still with the
confirmation that permanent deletion warrants.

The **Original Location** column is filled from two places. First, **Diptych's
own record** of what it moved to the Trash (`TrashOriginals`, a small JSON file
in `~/.diptych`), which is exact and needs no permission. For anything Finder or
another app trashed, Diptych falls back to **Finder's own "Put Back" record**,
which macOS keeps in a private, undocumented store -- the `ptbL`/`ptbN` records
inside the Trash folder's `.DS_Store` -- with no public API and only readable
with Full Disk Access (which Diptych asks for the moment a Trash is opened).
`TrashPutBack` reads it through the bounds-checked `DSStore` decoder,
pulling the original path straight out of each put-back bookmark without
resolving it against the disk, and never writes it back; the most that can go
wrong is a dash, or rarely a wrong path, never a crash. The JSON record forgets
an entry once its trashed file is gone -- the Trash emptied, the file put back,
or deleted immediately -- so it does not grow without bound. `Trash` says where
a volume's Trash is and what counts as one; the column itself is the
`FileColumn` case `originalLocation`, added to the table only for a Trash
listing.

The sidebar's per-volume bin button is a **deleted-items bin** (`xmark.bin`),
not a bare trash can, so it reads as "open this disk's Bin" rather than "throw
this disk away". It is hollow on a read-only volume, whose Bin is always empty,
and solid otherwise -- the same size either way, so the volume names stay
aligned.

## File servers

**Go ▸ Connect to Server…** (`⌘K`) mounts a file server and opens it in the
active pane. The other pane stays where it was, so copying to or from the server
is one keystroke.

| Address | Server |
| --- | --- |
| `smb://nas/photos`, or just `nas/photos` | Windows shares, most NAS boxes, Azure Files |
| `nfs://host/export/path` | NFS, including Google Cloud Filestore |
| `https://dav.example.com/remote.php/dav` | WebDAV: Nextcloud, ownCloud, many NAS boxes |
| `ftp://host` | FTP, which macOS mounts read-only |
| `afp://old-mac/share` | AFP, for old Macs and Time Capsules |

- **Signing in is the system's.** Mounting goes through NetFS, the same as
  Finder's Connect to Server: macOS shows its own name-and-password window, with
  *Remember this password in my keychain*, and asks which shares to mount when an
  SMB address names none. Diptych never sees a password, and a password typed
  into an address is never written down.
- **A folder inside a share opens directly:** `smb://nas/photos/2024` mounts
  `photos` and opens `2024` in it. A share already mounted, by Diptych or by
  Finder, is opened without asking the server again.
- **The sheet lists** saved servers (starred), recent ones, and those **on this
  network** -- NAS boxes and Macs that announce themselves by Bonjour. A click
  fills in the address, a double-click connects. The network is looked at only
  while the sheet is open, and macOS asks once for permission to do so.
- **SFTP** is not mounted: Diptych talks SFTP itself -- see
  [SFTP servers](#sftp-servers) below.
- **S3 and other object stores** cannot be mounted by macOS itself; the sheet
  says so, and names the tools that can (rclone, Mountain Duck). Once mounted
  that way they are folders like any other.

**Starred servers appear in the sidebar** under **Servers**, coloured when
connected and grey when not. A click connects one, or opens it if it is. Its
eject button disconnects it, and its context menu has **Connect When Diptych
Starts**, which mounts it at launch without opening anything. The list lives in
`~/.diptych/servers.json`, readable by you alone.

**A pane left on a server comes back to it.** When a pane arrives at a folder on
a server that is not connected -- at startup, or from the history -- Diptych
connects it and opens the folder. A server disconnected while a pane shows it,
by Finder's eject say, is not mounted again unasked: the pane stays where it
was, says which server it is waiting for, and offers **Connect** or **Go Home**.
After the Mac wakes up, panes on servers are listed again, and one whose server
went away while asleep connects it. Servers mounted by Finder are remembered too,
so this works for them as well.

**On a server, some things behave differently:**

- **Changes made on other machines show up.** The kernel reports only what this
  Mac changes, so a pane on a server looks at the folder every five seconds while
  Diptych is in front, and lists it again whenever Diptych comes to the front.
  Settings > Behaviour > File Servers sets how often; 0 turns both off, and
  only Refresh lists the folder again.
- **A folder listed before opens at once.** Going back into a folder on a
  server shows its rows as they were last listed in this run, and the status
  line says *as listed at 14:02, reading it again…* until the fresh listing
  replaces them. A folder never listed yet shows how many items have been read
  so far while it is being read.
- **A read-only server** -- FTP, or a share mounted read-only -- greys out New
  Folder, New File, Rename, Rename Many, Move to Trash, Paste as Link, the
  permission and owner commands, and Copy or Move into it; a drop or a paste
  into it says why it was refused instead of failing halfway. Text Edit and the
  binary view say the volume is mounted read-only -- not the file, whose
  permissions may well say `rw-` -- and the binary view takes no edits there.
- **A save is checked.** A WebDAV server is sent the file when it is closed,
  and a refusal then is reported rather than lost; the binary view reads the
  file back after saving and says so if the server did not keep the change.
- **What reads everything over the network says so first:** the flat view,
  Calculate Directory Sizes, and Compare Folders with Content ticked each show a
  note as they start. The flat view's Stop and Clear Directory Sizes end them.
- **Version tracking is off** for folders on a server: `git status` reads every
  file of the repository.
- **Picture and video columns fill in after the rows**, a few files at a time,
  instead of holding up the listing; a file that has not changed is not read
  again when the folder is listed again.
- **`._` files are hidden.** macOS keeps a file's tags and extended attributes in
  `._name` beside it on a server or disk that cannot hold them; Diptych leaves it
  out, as Finder does, even with hidden files shown -- on any volume.
- **NFS asks for no password:** the server goes by your user number, and a
  refused folder says so, with the number.
- **The sidebar shows each volume's size and free space**, looked at again each
  minute while Diptych is in front. A server's volume gets a network-drive icon
  rather than asking the server for its own, which takes seconds each.

**To try it out**, `test-servers/` has a script that sets up SMB (read-write
and read-only), NFS, FTP and WebDAV test servers on a Debian machine on your
network -- a Raspberry Pi will do -- all announced by Bonjour.

## SFTP servers

`sftp://user@host/path` in **Go ▸ Connect to Server…** connects to an SSH
server with Diptych's own SFTP client. The server appears in the sidebar as a
volume named after the host, and stays connected until it is ejected or
Diptych quits.

- **Signing in** tries the keys in the ssh-agent first, then the key files in
  `~/.ssh`, then asks for a password. A password is kept only while the server
  is connected, so a dropped connection is made again without asking; it is
  forgotten at eject and at quit.
- **Trusting the server.** The first time, Diptych shows the key's fingerprint
  and says whether `~/.ssh/known_hosts` already knows the host. What you trust
  is kept in `~/.diptych/sftp_known_hosts`; `~/.ssh/known_hosts` is never
  changed. A key that differs from the one trusted is refused, with the file
  and the lines to remove if the change is expected.
- **Keep Alive…**, in the server's sidebar menu, sets how often an idle
  connection is checked. The default is `ServerAliveInterval` from
  `~/.ssh/config`, else 60 seconds.
- **Paths are `sftp://` addresses** everywhere: the path bar, Copy Path, a
  dragged file (as text), and the MCP tools. Tab completes server paths.
- **Changes are made on the server:** rename, delete (permanent -- a server has
  no Trash, and the dialog says so), new folder, new file, New from Clipboard,
  copy and move both ways, drag and drop, permissions, modification time, owner
  and group. A change of owner the server refuses can be made as root through
  `sudo`, one command at a time; the session itself never runs as root. The
  sudo password is asked for, and kept as long as you choose, in memory only.
- **The Info window** shows the server's mode, owner, group and dates. Tags,
  extended attributes, access control lists and Open By are this Mac's, and
  are not offered for a server's file.

### What is kept on this Mac

A server's folders are listed into a cache under
`~/Library/Caches/<bundle id>/Opened Servers`, removed at eject and at quit.
A file is a placeholder there until its bytes are needed, and is fetched when
it is opened, previewed, copied, checksummed, shown in Text Edit or Bin Edit, or
looked at in the Info window -- whose listed facts show at once, while what is
read from the bytes (the signature, the details) waits for them.

- **A right-click fetches** the files it was made on that are no bigger than
  Settings ▸ Behaviour ▸ *On SFTP servers, fetch files up to … MB* (10 by
  default; 0 turns it off). A bigger one has **Download to Cache** in the menu.
- **The Cached column**, in server listings only, shows how much of each file
  is here, with a bar while it arrives. A mark after the name says the same: a
  pulsing arrow while it arrives, a tick once it is here, an orange circle when
  the server has changed the file since it was fetched. Size and date are
  always the server's.
- **A file the server changed** keeps the copy here, so whatever has it open is
  not pulled from under it; the next open, preview or right-click fetches the
  new version -- unless the copy here was changed, or a Diptych editor has
  changes to it not saved yet.

### Editing a server's files

A file fetched from a server can be edited in place, with Diptych's Text Edit
or Bin Edit or with any other app. When it is saved, Diptych sends it back --
but first checks that the server still has the version that was fetched. If
it does, the save is sent. If it does not, nothing is sent, and you choose:

- **Compare the Two…** (text only): the server's version and yours side by
  side; saving your side sends it.
- **Save Mine as a New File**: yours goes beside it on the server as
  `name-1.ext` (or `-2`, …), and the file itself becomes the server's again.
- **Keep Mine**: yours replaces the server's, whose changes are lost.
- **Keep the Server's**: the file here becomes the server's version, and your
  changes are lost.
- **Decide Later**: nothing is sent until the file is saved again. Ejecting the
  server, or quitting, asks first while a change has not been sent.

**What cannot be caught.** The check compares what is saved with the version
Diptych fetched. Diptych's own editors tell it when they hold changes not yet
saved, and while they do, the file is never fetched again under them. Another
app cannot tell it that. So if an app such as TextEdit has changes not yet
saved, and meanwhile Diptych fetches the server's newer version -- because the
file was opened, previewed or right-clicked again -- the version Diptych
compares with is the newer one. Most apps then warn that the file was changed by
another application; saving anyway replaces the server's newer version, and is
sent without a conflict being seen. To be safe with another app,
save before opening the same file again in Diptych, or edit with Text Edit or
Bin Edit.

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
with a circle between them for the recent folders, then the flat view's button
(see [Flat view](#flat-view)), and a filter on the right.

**Back / Forward** (`⌘[` and `⌘]`) walk that pane's own history of visited
directories. Going somewhere new after going back discards the forward trail,
as a browser does. History is per-session; it is not saved.

**The circle between them** lists the folders that pane has been in, most
recent first, each only once -- a folder visited again moves to the top. Pick
one to go there. Unlike Back and Forward it forgets nothing: go to A, B and C,
back to B, on to D, and back to B, and Back and Forward no longer reach C, but
the circle lists D, C and A -- B is where you are. Folders that are gone are left out. It keeps the last 30, and is saved with
the pane, so it is still there after a restart.

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

## Flat view

**View ▸ Flat View** (`⇧⌘F`), or the list button after `‹ ○ ›`, turns a pane
into one list of its folder **and everything under it**, filtered by an
expression much like `find`'s. The button is lit while the pane is flat; press
it again to go back to the folder. The path bar shows the folder the view is of,
and each row's name has its folder in front, in grey: `src/app/View.swift`.
Sorting by name keeps a folder's files together.

The filter and its two boxes give way to one long **expression** field, with a
button on its right that walks the tree with it (Return does the same). The
rows arrive as they are found, with how many so far and the folder being read;
**Stop** ends the walk and keeps what it found, marked as not complete.
Folders that cannot be read are counted, and listed in the tooltip.

```
size > 10MB and modified < 2025-01-01
(directory and name = "myDir") or (file and name = "*.txt")
directory traversed, file and contains ~ /TODO|FIXME/
name ~ /^IMG_\d+\.heic$/i and xattr("com.apple.metadata:kMDItemWhereFroms") ~ /icloud/i
```

Tests, joined with **AND**, **OR** -- or a comma, which reads as OR -- and
**NOT** (AND binds tighter than OR) and grouped with parentheses. Keywords and
the quoted values compared are case-insensitive. Texts are in quotes, where a
backslash is just a backslash. Regular expressions are between slashes,
`/…/`, as in many programming languages, and mind case unless `i` follows:
`/readme/i`. The other flags are `m` (`^` and `$` at every line), `s` (`.`
matches a line break) and `x` (spaces ignored); `\/` is a slash inside one.
They are not anchored: `^…$` for a whole name.

| Test | True when |
|---|---|
| `size <op> n` | the file's size compares: `=` `!=` `<` `<=` `>` `>=`, in bytes or with `B`, `KB`, `KiB`, `MB`, `MiB`, `GB`, `GiB`, `TB`, `TiB` (KB is 1000, KiB 1024). Never for a folder |
| `name = "pattern"` | the name is that, or matches the shell pattern (`*.txt`); `!=` for not |
| `name ~ /regex/` | a regular expression finds a match in the name; `!~` for not |
| `path = "pattern"` | the whole path is that, or matches the shell pattern, whose `*` here crosses `/`: `path = "*/.git/*"` is anything under a `.git` folder. A leading `~/` is your home folder. `!=` for not |
| `path ~ /regex/` | a regular expression finds a match in the whole path; `!~` for not |
| `directory` | it is a folder: listed, and walked into |
| `directory traversed` | it is a folder, to walk into but not list |
| `directory listed` | it is a folder, to list but not walk into |
| `file` | it is not a folder |
| `link` | it is a symbolic link -- to a file, to a folder, or to nothing. A link is also what it leads to: `link and directory` is a link to a folder, `not link` leaves links out. Not a kind: an expression with `link` and no `file` or `directory` still walks every folder |
| `link broken` | a link that leads nowhere -- the red dot: its target, or a link further along, is not there, or the links go round |
| `link loop` | a link that goes round: following it comes back to a link already passed, or it points to itself |
| `link not broken`, `link not loop` | short for `link and not link broken`, `link and not link loop`: a link that works, a link that does not go round. Unlike `not link broken`, which is true for every plain file and folder too |
| `access = "rwxr-x---"` | the permissions, place by place: `r` `w` `x` set, `-` clear, `*` either; `s` in the user's and group's `x` places for setuid and setgid, `t` in the last for sticky |
| `owner = "name"`, `group = "name"` | the owner or group; `~ /regex/` for a regular expression |
| `xattr("name")` | the extended attribute is there; `= "value"` or `~ /regex/` for its value (a property list's strings each count) |
| `created <op> date`, `modified <op> date` | ISO 8601: `2026-01-31`, `2026-01-31T14:30`, `2026-01-31T14:30:00+02:00` or `Z`. Without a zone, this Mac's; a date alone is the whole day, so `=` is within it and `>` after it |
| `contains "text"` | the text is anywhere in the file (also `content`) |
| `contains ~ /regex/` | a line of the file matches, as `grep` |

**Pictures and videos.** These tests read a file's header -- never its pixels
-- so they know it by its bytes, not its name: a JPEG named `notes.txt` is
still `image`.

| Test | True when |
|---|---|
| `image`, `video` | a picture macOS can read -- raw files and SVG drawings too -- or a movie |
| `exif`, `located`, `flash` | the picture carries EXIF; it records where it was taken; the flash fired |
| `landscape`, `portrait`, `square` | wider than tall, taller than wide, or neither, as it is shown |
| `rotated`, `transparent`, `animated` | turned by its orientation tag rather than its pixels; it has an alpha channel; it has several frames |
| `format = "heic"` | the bytes are that format, whatever the name says -- names below; `"raw"` is any camera's raw |
| `camera`, `lens`, `software`, `artist`, `copyright`, `description` | `= "*pattern*"` or `~ /regex/`, as the file says it. `camera` is the maker and the model together: `"Apple iPhone 15 Pro"` |
| `city`, `state`, `country` | the place names written in the file by photo software -- or, where none are, those of the nearest town of 15,000 people or more within 50 km of where it was taken. `country` is the name or its code: `"HU"` |
| `taken`, `digitized` | the date taken, and the date a scan was made, compared as `modified` is |
| `iso`, `aperture`, `shutter` | `iso >= 1600`; `aperture <= 2.8`, also `f2.8` or `f/2.8`; `shutter >= 1/30`, in seconds -- `2s`, `500ms` |
| `focal`, `focal35` | the focal length, and its 35mm equivalent: `focal35 < 24mm`, also `cm` and `in` |
| `width`, `height`, `megapixels` | in pixels, as the picture or video is shown |
| `altitude` | `altitude > 2000m`; `km`, `ft`, `yd`, `mi`; below the sea is negative |
| `rating` | the 0 to 5 stars Lightroom or Bridge wrote |
| `duration` | a video's length: `duration > 10min`, `s`, `h`, or `1:30` |
| `near(lat, lon, distance)` | taken within the distance of the place: `near(47.4979, 19.0402, 5km)`, `3mi`. The latitude and longitude are as Google Maps copies them |

The formats: `jpeg` (or `jpg`), `heic` (or `heif`), `heif`, `avif`, `png`,
`gif`, `tiff` (or `tif`), `webp`, `bmp`, `ico`, `icns`, `svg`, `psd`, `jp2`,
`jxl`, `exr`, `hdr`, `tga`, `pbm`; the camera raw formats `dng`, `cr2`, `cr3`,
`crw`, `nef`, `arw`, `raf`, `orf`, `rw2`, `pef`, `srw`, and `raw` for any of
them; and the videos `mov`, `mp4`, `m4v`, `3gp`, `avi`, `mkv`, `webm`, `mpeg`,
`flv`, `wmv`. MOV, MP4, M4V and 3GP videos say when and where they were taken,
the camera, their size and length; the others only that they are videos.

**What a file does not say makes its test false** -- with `!=` too, and `<`,
and `>`: a text file is not `taken < 2020`, and not `camera != "x"` either.
Only NOT turns that around, so `not camera = "*iPhone*"` lists every text file
and folder too. The line under the field says so, and `image and not camera =
"*iPhone*"` keeps to pictures.

**City, state and country** come from the file first. Without them, a
picture or video that knows where it was taken is placed in the nearest town of
15,000 people or more within 50 km, from a list in the app made from
[GeoNames](https://www.geonames.org) (CC BY 4.0) -- looked up on this Mac,
never asked of a service. A photo from a village is given the nearest larger
town; one from a sea or a desert, none. `make-places.sh` makes the list again,
from time to time.

The list is yours to correct, in `~/.diptych/exif/places.json` -- see [The
lists in ~/.diptych/exif](#the-lists-in-diptychexif).

**Dates to a year or a month.** For every date test -- `created`, `modified`,
`taken`, `digitized` -- `2024` is the whole year and `2024-07` the whole month:
`taken = 2024-07` is July.

**Ranges.** Anything that has an order takes `between`: `iso between [100,
800)`, `taken between [2024-06, 2024-08]`, `size between (1MB, 10MB]`. A square
bracket takes that end in, a round one leaves it out.

**Metric and imperial.** Distances in `m`, `km`, `ft`, `yd` or `mi`; focal
lengths in `mm`, `cm` or `in`.

`contains` never looks into a binary file -- one with a NUL byte near its
start, as `grep` and Git judge it: three letters turn up in an image's bytes
by chance, and that is never what was looked for. The rest of the expression
still counts for it: `contains "x" or name = "*.png"` lists the images.

**true, false and comments.** `true` and `false` are tests too: `false and (…)`
switches a part off without deleting it, and no warning is given for what it
makes impossible. So does a comment, `/* … */`, which may be anywhere and
span lines.

**Saved expressions.** Right-click the field -- its menu has the expression's
own items and the editing ones, nothing else: **Save Expression** lists the names already in use, to replace one, and **New Name…**.
Only an expression that parses can be saved. A name is a letter, then letters,
digits, `_` or `-`, and not one of the language's words; case does not matter.
A saved name can then be the expression, or part of one, and stands for its
expression in parentheses: with `images` saved as `name = "*.jpg" or name =
"*.png"`, `images and size > 1MB` means `(name = "*.jpg" or name = "*.png") and
size > 1MB`. Control-Space offers the saved names, and the line under the field
shows a name's expression. Each is a JSON file in `~/.diptych/filters`,
holding the expression and every version before it, newest first -- edit the
file to put an older one back. Saving is undoable: Undo puts back the version
before, or removes a name saved the first time.

A file there whose name is not allowed -- edited by hand, or saved before the
name became one of the language's words, as `image` did -- is ignored, and
Diptych says so when it starts, or when such a file turns up: each name, why
it is not allowed, and the file's full path. So does a file that is not a
saved expression at all.

One saved expression may use another. Replacing one says which others it
changes with it. If one that others use goes -- its file deleted, or its first
save undone -- Diptych says at once which stop working, and an expression
using them is underlined at the name, saying which is missing and through
which: *"jpegs" is no longer saved, and "images" uses it, which "photos"
uses*. They work again as soon as it is back.

**Folders.** A folder is asked twice: whether to list it, and whether to walk
into it. `directory` says yes to both, `directory traversed` only to walking,
`directory listed` only to listing. So
`(directory and name = "myDir") or (file and name = "*.txt")` walks only into
folders named myDir, below the top one, and lists them and the `.txt` files it
finds -- leave out `file` and a folder named `notes.txt` would be walked into
as well. `directory traversed or (file and name = "*.txt")` walks everywhere and
lists only the `.txt` files, and so does
`directory traversed, file and name = "*.txt"`. An expression with neither `directory` nor `file`
is about files alone: every folder is listed and walked into, and listed first
when folders come first. An empty expression lists everything. Links to folders
are listed but never walked into, so a link pointing above itself cannot send
the walk round for ever; packages and apps count as one item.

**Typing it.** While the field is being edited it grows to show all of a long
expression, and goes back to one line after. What does not parse is underlined
in red as you type, and the reason is under the field; until it parses the
button does nothing. What parses but cannot be what was meant is underlined in
orange, and said under the field. It can still be run.

- **Nothing can be listed:** `directory traversed` alone.
- **An AND that can never hold**, the two tests underlined: a file that is a
  folder (`directory traversed and file`, `directory and size > 1KB`); one
  permission bit both set and clear (`access = "***r**r**" and access =
  "***-*****"`: the group's read bit); sizes or dates in ranges that do not
  meet (`size > 10MB and size < 1MB`); two different exact names, owners or
  groups; an exact name that another test rules out (`name = "cat.jpg" and name
  != "*a*"`); two endings at once (`name = "*.jpg" and name = "*.png"` -- OR, or
  a comma, is either); a test and its opposite; an attribute's value tested
  where the attribute is not to be there; a picture and a video at once, or
  landscape and portrait; two formats; a picture's numbers or dates in ranges
  that do not meet (`iso > 800 and iso < 400`, `iso between [800, 100]`).
- **NOT over what a picture says**, with nothing beside it keeping to pictures:
  `not located` is true for every text file too. `image and not located` is not
  warned about, nor `not image` or `not format = "jpeg"`, which mean what they
  say.
- **No folder is walked into**, so only the top one is looked at: `file and
  name = "*.txt"`.

Not every impossible expression is caught, only the common shapes. A run that
finds nothing says so under the field. Otherwise the line under the field says
what the word at the caret takes. **Control-Space** offers what can come next
-- a test, a comparison, a unit, a keyword, a saved name -- starting with what
is typed of it; when only one thing can come next, it is inserted at once.
After `iso >`, `aperture <=`, `shutter >=` and the other numbers, it offers
their usual values -- ISO 100 to 12800, the f-stops, the shutter speeds, the
focal lengths -- and after one, its units. After `format =` it offers the
formats; after `camera =`, `lens =` or another of a picture's texts, what the
flat view found, the commonest first -- which needs the flat view to have run,
and says so when it has not. Inside `between [` it offers values, then `,`,
then `]` and `)`.
Where a date goes -- after `created`, `modified`, `taken` or `digitized` and a
comparison or inside `between [`, or on a
date already there -- it opens a **calendar** instead, starting at the date
written; tick **Time** for a minute too, and **Insert** (Return) writes it in
this Mac's time. After `access =` it offers
`"*********"`, and inside those quotes typing overwrites, as in the pane's
permission editor: `r`, `w`, `x` set that letter in the caret's three places
(Shift makes it `-`, Option toggles), `s` and `t` the special bits, and `-`,
`+`, `*` and Space set the place under the caret and move on -- Space goes
round letter, `-`, `*`. Backspace makes the place before `*`.

**Opening and coming back.** Return, `⌘↓` or a double-click opens a file as
usual, and opens a folder as a folder, leaving the flat view; Back returns to
it at once, from the walk it remembers, with the folder you came out of
selected. Each pane remembers its last six walks. Going anywhere through the
path bar, its links or the recent folders leaves the flat view too; with
Option held, the path bar's last folder is a link as well, back to that
folder. Option held over the rows, the folders before each name become links
too: click one and the pane goes to that folder, the cursor on the file or
folder that led there, and Back returns to the flat view. A flat pane is saved
as flat and walked again when Diptych starts.

**It holds still.** Only the expression's button (or Return in it) walks the
tree again. Renaming a row, or setting its permissions, changes just that row
-- a renamed folder takes its rows along -- and the row stays even when it no
longer passes the expression; the expression then turns **brown**, and the
line under it says the list is stale, until it is run again. Refresh (`⌘R`)
re-reads every row the same way: gone ones drop out, nothing else does.

**A source, not a target.** Rows can be copied, moved, renamed, trashed and
dragged out as anywhere else. Nothing can be copied, moved, pasted, dropped or
made *into* a flat view -- it is many folders, not one -- except by dropping
onto one of its folder rows, which is a folder. F5 and F6 on the function
bar are greyed while the *other* pane is a flat view, and F7 while this one
is; the keys, New Folder, New File and Paste say why. Rename Many works on the flat
view's rows -- see [Rename Many](#rename-many).

### The expression elsewhere

The language is not tied to the flat view. `FlatQuery.parse` turns a text into
a query, or a `Problem` with its place in the text, and everything else is a
question to that query -- from any thread, since neither type belongs to an
actor:

```swift
let query = try FlatQuery.parse("link and not directory").get()
query.matches(item)        // a FileItem: a row of a pane
query.matches(url)         // any path, read from the disk; false when nothing is there
query.matches(subject)     // a FlatSubject made by hand, as the tests do
```

`matches` asks an item the question as it stands. The walk's own rules belong
to `decide`, which the flat view uses: there, an expression that names no kind
lists every folder and walks into it, and a folder is asked twice -- whether to
list it and whether to walk into it. Under `matches` a folder is just an item,
asked once, the way it is listed: `directory` and `directory listed` hold for
it, `directory traversed` does not, and `name = "*.app"` matches a folder of
that name.

`path` is for this use above all: asked of one item, nothing is walked, so
`path != "*/.git/*"` is how to leave out what is under `.git`. In the flat
view itself, not walking into the folder is cheaper --
`directory traversed and name != ".git", file` never reads it -- while
`file and path != "*/.git/*"` reads everything in it and then drops it.
Scripts' `apply-to` header is the language used this way.

A new test is a `Primitive` case, its word in `FlatQuery.primitives` (which
also makes it a word a saved expression cannot be called), its parsing, its
hint, and its answer in `FlatEvaluation` -- plus a cost there, if answering
it needs more than what the listing already knows.

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

## The Rename menu

On the right-click menu **Rename** is a submenu, like Copy: clicking the word
renames the one selected file in place, and the arrow opens the rest.

- **Rename Many…** and **Suggest Name…** are the windows below and the Apple
  Intelligence suggestion.
- **Lower Case** and **Upper Case** change the whole name's letters.
- **Spaces to Underscores** and **Spaces to Dashes** replace every space in the
  selected names.
- **Replace…** opens a window that finds text A in the selected names and puts B
  in its place -- every occurrence, anywhere in the name, which is *not* the
  whole-name match Rename Many does. A checkbox makes A a regular expression and
  B its replacement, so `\s+` → `-` collapses each run of spaces to one dash
  across the whole selection. The new names are previewed before anything runs.

Each acts on the whole selection, runs through the same collision-safe planner
as Rename Many -- nothing touched unless the lot is sound -- and is a single
Undo step.

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

**Placeholders in the replacement**, filled from each file so the same
replacement gives a different name per file, alongside the regex's own `$1`:

- `$n` — a serial number, 1, 2, 3 … in the order the files are listed;
- `$cdate{YYYY-MM-DD}` and `$mdate{YYYY-MM-DD}` — the created and modified dates,
  in a format you give (the everyday `YYYY`/`DD` are understood);
- `$owner` and `$group` — the owning user and group;
- `$exif{DateTimeOriginal}` — an EXIF value of an image, by its name.

The small grey line under Replace lists them, the braces button inserts one, and
**Control-Space** opens the same list in the field. What a placeholder fills in
is put in literally, so a value that happens to contain a `$` can never turn
into a backreference by accident.

**The selection.** When files are selected in the pane, **Selection only** is
ticked: only they are matched and renamed, the rest are dimmed -- though their
names still count as taken. Untick it for the whole folder. With nothing
selected the box cannot be ticked. After renaming, the renamed files are still
the selection, under their new names.

**From a flat view**, the window works on the flat view's rows, each with its
folder in front of its name, and renames each in its own folder. The rows are
the ones the pane **lists** -- in a stale view too -- not what the expression
would find now. A clash is looked for among every name in each folder, listed
or not, and said with the folder it is in. A folder is renamed after what is
in it. The pane follows the renames row by row, as it does after any rename.

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
at the end, which the window says out loud. A longer loop takes the same single
step aside: `(.)(..)` → `$2$1` on `ABC`, `BCA` and `CAB` turns each into the
next -- `ABC` steps aside, `CAB` becomes `ABC`, `BCA` becomes `CAB`, and the
parked file becomes `BCA`. Every disjoint loop costs one temporary name. A step that fails stops the run,
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
folder, New from Clipboard, a link, **Move to Trash**, a permission change, an
**owner or group change** — from the panes or from the Info window — an
**EXIF change** and a **Paste Special**. The menu names the step: *Undo Move*, *Redo Rename*.

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
* **A change inside a file comes back byte for byte.** An EXIF change rewrites
  the file, so before it is written a copy is kept — a clone on the same disk,
  costing no space until the file changes — and undoing puts that copy's bytes
  back into the same file. Redo keeps a copy the same way before undoing it.
  The copies live in `~/Library/Caches/dev.verhas.Diptych/Undo/`, one folder
  per running Diptych, and go when the history does: a folder left by a
  Diptych that has quit is removed at the next start. If the file has been
  changed since, the question says that what was changed in it is lost.

One history for the whole application, as in Finder, fifty steps deep, kept in
memory: after a restart the paths it holds may describe a world that has moved
on. While a rename field or the path bar is being typed in, ⌘Z undoes the
typing, and in a comparison window it is that window's own undo.

## Editing EXIF

**Right-click ▸ Image ▸ Edit EXIF…** appears when the selection holds a JPEG or
HEIC image, and opens a window for every such image selected; anything else in
the selection is left out. The images are listed at the top, each with its
full path — the window lives on its own, apart from the pane it came from, and
an agent can open it on images from different folders. Click one to pick it:
**Space** shows it in Quick Look, **Return** or **F3** opens it, and a
double-click opens it too; right-click for **Open**, **Quick Look** and **Copy
Path**. Their fields are below, in three groups: Image and Camera (the TIFF fields — description,
artist, copyright, make, model), Photo (dates, time zone, lens, exposure, ISO)
and Location (GPS).

- **A field shows its value** when every image has the same one. When they
  differ, or only some have it, the field is **grey and empty** —
  *Different in each file* — and what you type replaces every image's value.
- **Typing in a field ticks its box**: ticked fields, and only those, are
  written on **Save**. Untick it and the field greys out, keeping what you
  typed; click back into it and the box is ticked again and the editing
  carries on, with no need to tick the box first.
- **A description from Apple Intelligence.** Opened on one image with no
  description, the editor asks Apple Intelligence for one in the background —
  Vision says what the picture shows, and the model on this Mac (never Private
  Cloud Compute) puts it into a sentence. While it works the field says so.
  The sentence arrives grey and unticked, as if typed and then unticked, and
  is written only if you tick it; it goes only into a field you have not typed
  in meanwhile. Off when Apple Intelligence is off in Settings.
- **The minus button** removes a field from every image (the value is struck
  through; the arrow takes the mark off), and an emptied field is removed too.
  **Add Field** shows a field the list does not have yet; a field added and not
  wanted goes again with the same button. Values ImageIO keeps for itself —
  pixel dimensions, versions, the Flash structure — are shown but not editable.
- Numbers take fractions — an exposure time of `1/125`.
- **Comment takes letters without accents only**: macOS writes it a byte a
  character, so `Új` came back garbled and the rest cut off. It is red, and
  Save waits; Description keeps accents.
- **A save that fails keeps what was typed**: the message says which file
  would not keep which field, and the fields stay as typed, to mend and save
  again.
- **Copy and Paste as JSON** -- the two buttons beside Add Field. Copy puts
  every field with a value on the clipboard, `{"Exif": {"DateTimeOriginal":
  "1978:01:01 00:00:00"}, "GPS": {…}, "TIFF": {…}}`; Paste types the fields
  from such JSON into the window, ticked, to be checked and saved as any typing
  is -- the names alone, without their groups, do too. To keep a long edit
  that cannot be saved, or to give one picture's values to others.
- **Control-Space in Camera Make, Camera Model, Lens Make or Lens Model**
  offers the usual values, as cameras write them -- `NIKON CORPORATION` and
  `NIKON Z 6_2`, not the names on the box. What is typed narrows the list;
  a model's list is the models of the make written above it, when that make
  is listed. The values come from `~/.diptych/exif`, below.
- **Save** is an **EXIF Change** in Undo, for all the images at once.
  Its shortcut is **⌘S**, not Return, which saved half-finished typing too
  easily. **Escape does not close the window**, so a slip of the finger does
  not lose what you typed: close it with Cancel, ⌘W or its close button.

### The lists in ~/.diptych/exif

Three JSON files, written the first time Diptych starts, for you to correct
and add to; Diptych reads them as it starts.

| File | What it holds | Used for |
| --- | --- | --- |
| `cameras.json` | camera makes and models | Control-Space in Camera Make and Camera Model |
| `lenses.json` | lens makes and models | Control-Space in Lens Make and Lens Model |
| `places.json` | countries, regions and the towns of 15,000 people or more, from GeoNames | a picture's or video's `city`, `state` and `country` when it has a location but no names |

One item to a line, so even thirty thousand towns can be searched and edited
as text:

```json
{"disabled":false,"make":"Apple","model":"iPhone 15 Pro"},
{"country":"HU","disabled":false,"id":3054643,"latitude":47.4984,"longitude":19.0404,"manual":false,"name":"Budapest","region":"05"},
```

- **`"disabled": true` takes an item out of use** -- a wrong camera name, or a
  district GeoNames lists as a town of its own. Nothing ever sets it back.
- **Add an item** by adding a line. A town you add needs only its `name`,
  `latitude` and `longitude`; `country` and `region` are codes, as in the
  others.
- **Each file says which version of Diptych last wrote it** (`"version"`). The
  first start of a new version merges its own lists in: what you added stays,
  and what you disabled stays disabled. A camera or lens already there is
  left as it is. A country, region or town already there takes the new
  version's values -- a corrected coordinate, say -- unless its `"manual"` is
  `true`: set that on one you corrected by hand. While the version is the
  same, the files are only read.
- **A file that is not valid JSON is left as it is**: Diptych says which, and
  where the mistake is, and uses its own list until it is mended.

**Right-click ▸ Image ▸ Delete All EXIF Data** takes every EXIF, TIFF and GPS
field out of the selected images at once — and the XMP copy of camera
details EXIF has no field for, such as the lens and its serial number — with no
question asked: a message says *3 files' EXIF data was erased, undoable*, and
it is one **Delete EXIF** step in Undo. Orientation stays, or the picture would
show turned; the picture itself is not re-encoded. Other XMP — Lightroom's
settings, a rating — is not EXIF and stays.

**Right-click ▸ Image** is there for any picture -- PNG, TIFF, GIF and the
rest too; the EXIF items only for JPEG and HEIC. Each of these is one step of
Undo:

- **Remove Location** takes out where the images were taken -- every GPS
  field, and the city, state, country and location names photo software keeps
  beside them -- and nothing else: for sharing a picture without the place.
- **Rotate Left, Rotate Right, Flip Horizontally, Flip Vertically**: a JPEG or
  HEIC is turned by its orientation alone -- nothing is decoded or compressed
  again, so nothing of the quality is lost -- and any other picture by its
  pixels, which PNG and TIFF keep exactly. The rest of the metadata stays. An
  open Quick Look shows the picture turned.
- **Set as Desktop Picture**, for one image, on every screen. It changes no
  file, so it is not in Undo.

And three that make **new images**, next to the originals -- or into the other
pane's folder -- never touching them; one Undo step moves what was made to the
Trash:

- **Convert…** to JPEG, HEIC (where this Mac can write it), PNG or TIFF, with
  a quality for JPEG and HEIC, the metadata kept or left out. `IMG_1.heic`
  becomes `IMG_1.jpg`; a name already taken gets a number, `IMG_1-1.jpg`. A
  transparent picture goes onto white for JPEG.
- **Resize…** to a longest side -- 4096 down to 640 pixels -- in the same
  format or another: `IMG_1 (2048).jpg`. The picture is turned upright on the
  way, and an image already smaller is not made larger. Convert and Resize are
  one dialog.
- **Remove Background** finds the subject with Apple's Vision, on this Mac, and
  saves it on a transparent background as `IMG_1 (cut out).png`. A picture with
  no clear subject -- a landscape, a texture -- says so and makes nothing.
- **Recognize Text…** reads the text in the pictures with Vision, and asks
  where to keep it: in a text file beside each, `IMG_1.jpg.txt`, which
  Spotlight, `grep` and the flat view's `contains` all find; or as the
  picture's Spotlight comment attribute,
  `com.apple.metadata:kMDItemFinderComment`, which the flat view's `xattr`
  finds but Finder's Get Info does not show. A picture without text is only
  counted; an existing text file is left alone.

**Help with the values**, and a way past it. Each helper has a keyboard button
beside it for typing the value instead, and a button back:

- **Dates and times** are edited a part at a time — year, month, day, hour,
  minute, second: click a part, or move with Tab and the arrow keys, type, or
  step with Up and Down. A new number starts only when a part is full or
  another part is chosen, never after a pause: `NSDatePicker`, used at first,
  starts again after a moment, so "202", a breath, "6" made the year 6. A digit
  no other can follow completes its part (a 4 in a month is April), and the
  day keeps within its month. Delete takes back the last digit of a part even
  after it is complete, so 1976, Delete, 7 is 1977. A date also has a calendar
  button, for picking the day on a month; the time of day stays as it was. The date is shown as written: EXIF dates have no
  zone, so nothing moves them into this Mac's. An empty one has **Set**, which
  starts from now.
- **Time zones** are picked by name, from a menu by region — *Europe ▸
  Budapest (+02:00)*. What is written is the zone's offset **on each image's
  own date**, so a summer photo gets +02:00 and a winter one +01:00 from the
  same choice.
- **Fields with a list of values** — Metering Mode, Exposure Program, Light
  Source, Orientation, White Balance, the N/S and E/W of a coordinate, and the
  rest — have a menu of what EXIF defines: *Spot (3)*.
- **Latitude and longitude** are checked: at most 90° and 180°, the hemisphere
  being its own field. They are typed as decimal degrees, degrees and minutes,
  or degrees, minutes and seconds — `47.4979`, `47° 29.874′`, `47 29 52.44 N` —
  and a minus sign or a letter sets the N/S or E/W field to match. An `o`
  typed in a coordinate becomes the degree sign as it is typed. The button in
  the **Location** heading goes round the three ways of writing them and
  rewrites the coordinates on show, without ticking them: the value is the same.
  **Pasting a place** into either fills all four fields — latitude, longitude
  and their N/S and E/W — from what Google Maps copies: a pair like
  `47.469405929393155, 8.673649728835294` (or `47°28'09.9"N 8°40'25.1"E`), a
  link like `https://maps.app.goo.gl/…` (Apple Maps links too), or a plus code
  like `FM9F+MFR Brütten`. A short link is followed to the map it stands for,
  and the town after a short plus code is looked up with Apple's geocoder:
  those two need the network, and the field says *Looking up the place…*
  meanwhile. A full plus code (`8FVCFM9F+MFR`) and a pair need nothing.
  When both are there, a small world map under them pins the place; click it
  to open the place in Google Maps in the browser. The map is drawn from
  [Natural Earth](https://www.naturalearthdata.com)'s public-domain coastlines
  shipped in the app, so it needs no network.

**Orange is unusual, red is wrong.** A value EXIF can hold but a camera would
not write is shown in orange, with why, and is saved if you leave it: a date in
the future or before 1975, when the first digital camera was made (a scan of an
old photo may well say 1962); a GPS date before 6 January 1980, when GPS time
began; a date not written as EXIF writes it; an offset
no time zone has; a value not on a field's list; a direction of 400°. A value
that cannot be written as it is — a latitude of 4637299321312, a word where a
number goes, a GPS time of 25:00 (stored as numbers, not text) — is red, and
Save waits until it is put right.

**Image Width and Image Height** are worked out by ImageIO from the picture. They
can be removed, and **Add Field** puts them back with each image's own size;
they are never typed.

**The picture is not touched.** The EXIF is changed with ImageIO's lossless
route, `CGImageDestinationCopyImageSource`: the image data is copied across as
it is, not decoded and encoded again. The file is written in place, so it stays
the same file, with its other names, permissions and attributes.

**What is written is read back first.** ImageIO accepts some changes and then
drops them on the way out, without a word, so the new file is read back in
memory and compared field by field; an image where something did not take is
left as it was, and the window says which fields. Finding the ones it drops is
why some fields are written the way they are:

- A number that is not whole is written as a fraction, `14/5`: handed over as a
  number, 2.8 was written as 2. Latitude and longitude are the exception — XMP
  writes them as degrees and minutes, and they take a plain number.
- Artist is written as a list of one name, and with an Orientation of 1 beside
  it when the image has none (which means the same: upright). A HEIC image
  dropped it otherwise, and so did a JPEG without other TIFF fields.
- GPS date and time are one value in XMP, so they are written together: one at
  a time, the date came out as 1916:01:00.
- ISO is written as one number, not a list of one, which HEIC drops.
- A HEIC image keeps altitude, direction and speed only with a latitude, and
  the window says so.

**From an agent**, `open_exif_editor` opens the same window on images from
any folders at once (see *Local agent access*).

**Why only JPEG and HEIC.** PNG and TIFF are written too, but ImageIO keeps some
of their old EXIF values whatever is written — a changed comment stays as it
was, a removed lens stays put — and AVIF it refuses outright. A test writes
every field the window offers, alone and all together, into both JPEG and HEIC
and checks each one stays.

## Comparing two files

**⌘D**, File ▸ Compare, or the toolbar: two files side by side -- two selected
in one pane, or one in each. The diff is the standard library's; what Diptych
adds is the alignment. A rewritten line shows as one changed line, not as a
deletion followed by an addition, and a run of changed lines counts as one
difference, because that is what "next" means to a reader. The words that
changed are marked within each line.

**In single-pane mode the hidden pane is never consulted.** With both panes
shown, one item selected in each compares across. With only one pane on screen,
the other is out of sight and must not be guessed at: two items selected there
compare with each other as before, and **one** item compares with its own
**committed version in Git** -- its uncommitted changes, read with `git show
HEAD:` locally, no fetch and no server. A file Git does not track (or a folder)
has no committed version, and Compare says so rather than reaching into a pane
that is not there.

There is find, jumping between differences, *only what differs*, *ignore
spacing*, and wrapping that applies to both sides or to neither.

- **A padlock on each side, and only one opens.** To edit the other file, save,
  close and compare again -- editing both halves at once makes it easy to lose
  track of which is which. Return splits a line, Backspace at its start joins
  it to the one above, Escape puts the line back, and one visit to a line is
  one undo step. **One press takes a whole difference from the other side**,
  and one press undoes it.
- **Saving keeps what is easy to lose**: the line endings, whether the file
  ended in a newline, its encoding, and its permissions, owner and extended
  attributes. An unchanged file is never rewritten, and a file something else
  changed since the window opened is refused rather than overwritten.
- **The window keeps up.** It watches both files and reloads when either
  changes, including when a file is replaced outright. It never throws away
  typing on the side you unlocked; Save warns about that instead.
- **Replace "name"** appears when a file is compared with its own `(my
  version)` copy: one press saves it, puts it in the original's place, and
  sends the old version to the Trash.
- **Everything besides the text, under the names.** One line says whether the
  two differ in anything else, and in what: size, permissions, owner, group,
  flags, the modification and creation dates (to the nanosecond, when they
  are the same second), the access control list and each extended attribute
  by name. The arrow opens the values side by side, the different ones
  marked, and *Show the same ones too* adds the rest. A tag list or other
  property list attribute is shown as what it holds, text as text, and
  anything else as hex. It opens by itself when the text is the same and
  something else is not, which is what the folder comparison or a sync meant
  by "different". Two files whose text is the same but whose bytes are not
  -- line endings, a byte-order mark, another encoding -- are said to be so.
  A chmod, a new tag or an attribute set elsewhere shows up at once.

## Previous versions

**File ▸ Previous Versions…**, or the right-click menu on a single file, opens
that file's earlier selves out of this Mac's APFS snapshots -- the hourly
*local* snapshots macOS keeps whether or not a backup disk is attached, and,
when the backup disk is there, Time Machine's longer history. Each version is
listed newest first, with its date, where it came from (a local snapshot or
Time Machine) and its size. A run of snapshots in which the file never changed
is **collapsed to the one moment it last did** -- by size and modification
date, without reading the bytes -- so a file saved once a week is not listed a
hundred times over.

- **Compare** (or **⌘D**) opens the chosen version against the file as it is
  now, in the ordinary comparison window -- the version on the left, the file on
  the right. The version lives in a read-only snapshot, so the comparison can
  never change it. The Previous Versions window stays open behind it, so you
  look, decide, and come back for another version until one is right or you
  close it.
- **Restore** copies the chosen version's bytes over the file, in place. It is
  *not* a whole-volume rollback: the file keeps its name, its permissions and
  its extended attributes -- only the contents change -- and it is a single
  [Undo](#undo-and-redo) step, so a restore you did not mean is one press to
  take back. It asks first, naming the moment it would go back to.
- **How it reads them.** macOS mounts snapshots under `/Volumes/.timemachine`;
  Diptych reads them there with Full Disk Access and never mounts anything
  itself or asks for a password -- so a snapshot the system has not exposed is
  shown as present but unavailable rather than forced open. Grant Diptych Full
  Disk Access (the window says so when a read is refused), and attach the backup
  disk to reach versions older than the local snapshots. Only a file on a real
  local volume has versions: a file inside an [opened archive](#archive-opened-as-a-folder)
  is a copy in the caches, not one with a history. See also [Unreadable
  folders](#unreadable-folders) on why a Time Machine backup cannot itself be
  opened as a folder.

The reading and the restore are in `FileVersions`; the window is
`FileVersionsView`. `FileVersions.list(for:)` finds the timestamp folders the
system exposes (under `/Volumes/.timemachine` and the local-snapshots volume),
newest first, and resolves the file within each by searching a couple of levels
down -- a local snapshot keeps it under `Data`, a Time Machine backup under a
volume-named folder, and this does not hard-code either. Identical consecutive
versions are then collapsed by size and modification date. Restore is a `FileHistory` *content* change
-- the same undoable step an EXIF edit uses -- so a copy of what the file held
goes to `UndoSnapshots` first.

## Checksums

**Checksum ▸ Create ▸** a kind writes a file's sum into a little text file
beside it, and **Checksum ▸ Check** tells you whether a file still matches a
sum. Both are also on the right-click menu, and both act on whatever ordinary
files are selected. The kinds are **MD5**, **SHA-1**, **SHA-256** and
**SHA-512**.

- **Create** makes `name.ext` next to each selected file -- `photo.jpg.sha256`
  for a SHA-256 of `photo.jpg` -- holding the sum in the `hash  name` layout
  that `md5` and `shasum` read and write. Several files selected make several
  checksum files at once, each beside its own file. Creating is a single
  [Undo](#undo-and-redo) step.
- **When the checksum file is already there**, Diptych does not blindly rewrite
  it. If it already holds the right sum there is nothing to do, and it is left
  untouched. If it holds a *different* sum -- the file has changed since --
  Diptych names it and asks before overwriting it with the new, correct sum.
  With several files selected, the ones that need a fresh checksum are written
  straight away and only the stale ones wait on that one question.
- **On read-only media** -- a disk image, an opened archive, a share mounted
  read-only -- the checksum file cannot go beside the original, so Diptych asks
  whether to put it in the other pane instead, and makes it there if you say so.
- **Check** looks first at the clipboard. With **one** file selected and a
  checksum copied -- a bare hash, or a whole `hash  name` or `MD5 (name) = hash`
  line -- Diptych computes all four of the file's sums (one pass over the file,
  so it is cheap) and tells you which kind matched, or that none did. 
- With **nothing** copied, or with **several** files selected -- where a single
  copied sum could not be said to belong to any one of them -- Check instead
  looks for the checksum files beside each selected file. Every one it finds is
  weighed against its file and reported as matching or not, so a file with both
  a `.md5` and a `.sha256` beside it is checked against both.
- Either way the result is a popup naming the kind of sum and, on success, what
  it matched: the clipboard, or which checksum file.

The hashing and the file format are in `Checksums`, off the main thread and
tested on their own; what is selected, what the clipboard holds and the
read-only detour are in `ChecksumActions`. `Checksums.allDigests(of:)` feeds one
read of the file to all four hashers at once.

## Compare Folders

Select two folders -- one in each pane, or two in one -- and press **⌘D**.
Every file is paired with its match on the other side, or listed on its own
when it has none.

**Matched by path, or by content.** A pair is the same relative path on both
sides. A file with no match by path is paired with an unmatched file of the
same bytes elsewhere, which is what a rename looks like after a folder was
copied. Only with *Content* ticked: without reading the bytes, a rename cannot
be told from an unrelated file of the same size. Folders and links are never
matched by content.

**What differs is shown as letters**, each in its own colour, with a legend
at the foot of the window:

| | |
| --- | --- |
| **F** | one is a file, the other a folder |
| **N** | matched by content -- the name or the place differs |
| **S** | size |
| **C** | content |
| **P** | permissions |
| **X** | extended attributes |
| **A** | access control list |
| **M** | modification date |
| **B** | creation ("born") date |
| **O** | owner or group |

Hovering over a row says which side is newer when a date differs, and *Same
content as: …* for a file whose bytes appear more than once. Empty files are
left out of that, since every empty file matches every other.

**What is compared** is a checkbox each, on the window: Content, Permissions,
Extended attributes, ACL, Modified, Created and Owner/group. Settings holds the
defaults: content alone, out of the box. Access time is not offered, because
comparing a file reads it, which changes it. **Refresh** appears when a box
changes after the run, filled in when a checkbox is the reason. Folders whose
names start with a dot, such as `.git`, are listed but not opened unless
*Recurse into hidden folders* is ticked. When the two folders being compared
are dot-folders themselves, they are opened by default.

**The list** has the panes' filter -- a fragment, a shell pattern, or with
*RegEx* a regular expression, with *Hide* to leave out what does not match --
plus **Only differences** and **Ignore missing** (what exists on one side
only).

- **⌘D**, or a double-click on a pair of folders, compares just those two.
  On a pair of files it opens the two-file comparison above.
- **⇧⌘I**, or **Properties**, shows the two sides' permissions, owner,
  flags, dates, ACL and extended attributes next to each other, what differs
  first -- for two folders or two links as much as for two files.
- **⌘I** opens Get Info on whichever sides exist, to compare tags, attributes
  and ACLs by eye.
- **⌘G**, or **Go to**, sends the pair back to the window the comparison came
  from: each pane selects its side, and the left one becomes active. With one
  side only, only that pane moves.

An agent can read what the window shows through `get_directory_diff`, and
open one with `open_diff`.

### Syncing both ways

**Sync ▸ Sync Both Ways…** is for two folders where neither is the master --
a laptop's copy and a server's, say -- and each change should go whichever way
it was made.

After every sync Diptych records how each path stood on each side, in
`~/.diptych/sync`, one small JSON file per pair of folders -- size,
modification date, permissions, and a digest of attributes, ACL and owner.
The next sync measures each side against that record:

| Since the last sync | Suggested |
| --- | --- |
| changed on one side | carried to the other |
| new on one side | copied to the other |
| deleted on one side, unchanged on the other | deleted there too |
| renamed on one side (same bytes, the N badge) | renamed on the other |
| changed on both sides | **conflict** |
| deleted on one side, changed on the other -- for a folder, anything in it | **conflict** |
| differs, though neither side changed | **conflict** |
| only a folder's dates differ | the newer dates, never a conflict |

Every row of the list has a menu: *Left → right*, *Left ← right* (or *Delete
on the right/left*), *Keep both* for two files, and *Leave as is*. A conflict
starts on **Decide…**, and Sync waits until every one is decided; **Newer
Wins**, **Keep Both** and **Leave as Is** decide them all at once.

- *Keep both* changes both folders: each ends up with both files, the newer
  under its name and the older beside it as `name (right copy).ext`.
- *Leave as is* changes nothing: each side keeps its own, and the next sync
  asks again -- as it does for anything that fails.

Two files at the same path show their name as a link: a click opens them in
the comparison window, to see what differs -- or to edit one into the other
before deciding. When it is not the text that differs, the window says what
does: permissions, dates, attributes, the ACL. Two folders or two links show
their properties side by side in a popover instead.

**The first sync** of two folders has no record to go by, so nothing on one
side only can be told to be a deletion: it is copied to the other side, and
two different files at the same path are a conflict. **Forget the Last Sync**
starts over from there. The panes may be swapped between syncs; the record
is found either way. Files changed on both sides are not merged -- for that,
use git.

### Making one folder the same as the other

**Sync ▸ Make Right Same as Left →** (or **← Make Left Same as Right**)
leaves the target folder as deleting it and copying the source over it would
-- content, permissions, extended attributes, ACLs, modification and creation
dates -- but touches only what differs:

- missing from the target: **copied**, a folder with everything in it;
- not in the source: **deleted**;
- content differs: **replaced** -- the new copy is made beside the old file and
  takes its name only once it is whole, so a dropped server connection leaves
  the old file as it was;
- only permissions, attributes, ACL or dates differ: those are **set**, the
  bytes are not copied again;
- the same bytes under another name or in another folder (the **N** badge):
  **renamed** there, not copied a second time;
- a file where a folder should be, or a link that differs: deleted and copied.

The folders are compared again first, then the window lists every change
before anything is made. Deleted items, and the old versions of replaced ones,
go to the Trash; *Delete outright* is there for a server whose volume has none.
Folder dates are put back after their contents changed. A failed step is
listed and the rest go on; **Stop** stops after the current file.

The sync goes as far as the comparison looks: with *Modified* unticked, two
files that differ only in their dates stay as they are. Whatever is copied or
changed gets everything, ticked or not. One folder inside the other cannot be
synced.

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

Under the verdict is the same properties line as for two texts: permissions,
owner, dates, ACL and attributes, side by side.

## Text Edit

Right-click a file ▸ **Text Edit** opens it as plain text in Diptych's own
editor, one window per file, whatever application the file would normally open
in. For a JSON, XML, YAML or TOML file the item is named for it -- **JSON
Edit**, **XML Edit** and so on, by the extensions in Settings. Beyond typing, undo, find and replace (⌘F), wrapping and Save (⌘S) it
edits by lines as IntelliJ does, and for JSON, XML and YAML it colours, pairs,
indents, formats and shows the file as a tree -- see below. It is careful
where general editors are not:

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

**The gutter**, left of the text, from left to right:

* **What changed since the last commit**, as IntelliJ shows it: a green bar
  beside added lines, a blue one beside changed lines, a red wedge where lines
  were deleted. Shown when Version Tracking is on in Settings and the file is in
  a repository; a file not in the last commit is all green. The commit is read
  again whenever the window comes to the front.
* **What changed since the last save**, in a thinner bar of its own, because
  Text Edit does not save by itself: teal for added, orange for changed, an
  orange wedge for deleted. Saving clears it.
* **Line numbers**, switched by the bar's button between absolute, relative to
  the caret's line as vi's `relativenumber` -- the caret's own line keeps its
  number -- and off, as in Tychedit. Remembered for every window.
* **Chevrons that fold** the structure of a JSON, XML, TOML or YAML file: an
  object or array between its brackets (`"windows": [ 4 items ]`), an element
  between its tags, a comment or CDATA, a TOML table down to the next one and
  an array or string over lines, what is indented under a YAML line. A badge
  stands for what is folded; clicking it opens it, as do Find or typing into
  it. Fold All and Unfold All are in the bar. Nothing is taken out of the text:
  saving, undo and find see all of it.

**Which format a file is** is decided by its extension: `json` is JSON, `xml`
XML, `toml` TOML, `yml` and `yaml` YAML. Settings ▸ Behaviour ▸ Text Edit adds
more -- `geojson, jsonc` for JSON, say -- or empties a format to treat its
files as plain text.

**A file that breaks its format** says so as it is typed: a red line under the
bar -- *Not valid JSON — line 12, column 5: A comma or } is expected after the
value* -- with **Show** to put the caret there, the line's number in red in
the gutter, and the place underlined. A well-formed file shows its format with
a green tick. JSON and TOML are checked completely, XML for being well formed
-- tags in pairs, attributes once each and in quotes, entities, one root --
and YAML for the mistakes people make: tabs for indentation, a line indented to
no level above it, a key under a line that already has its value, a line in a
mapping that is no key, a key set twice, a quote or a bracket not closed.

**Typing XML** is helped along, in a file Text Edit takes as XML:

* **What the markup still needs is shown in grey** after the caret: `>` once a
  `<` is typed, and while the tag's name and attributes are; `">` in an
  attribute's value; `-->` in a comment, `?>` in a processing instruction,
  `]]>` in CDATA. **Control-Space takes it**, the same as typing it.
* **After an attribute's name** the grey text is `=""`, and `""` after its
  `=`: Control-Space puts them in with the caret between the quotes, ready
  for the value -- `<item id` becomes `<item id="|"`.
* **After `</`** the grey text is the name of the innermost element not yet
  closed, and its `>`: `</` in `<root><item>` offers `item>`. Typed letters
  narrow it -- `</it` offers `em>` -- and Control-Space finishes the tag.
* **Closing a start tag puts in its end tag**: typing `<item>`, or taking the
  grey `>`, gives `<item>|</item>` with the caret between them. Not after
  `<br/>`, and not when an `</item>` further on already closes it. Undo takes
  back the end tag first, then what was typed.

The grey text is drawn only where nothing follows on the line, since it would
cover it; Control-Space takes it all the same. If Control-Space switches the
keyboard's input source instead, that is macOS's own shortcut -- **System
Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Input Sources** frees it.

**Editing by lines**, in any file, as IntelliJ does it:

| Keys | |
|---|---|
| `⇧⌘↑` / `⇧⌘↓` | move the caret's line, or the selected lines, up or down one line |
| `⌘⌫` | delete the caret's line, or the selected lines; the caret keeps its column |
| `⌘C` / `⌘X` with nothing selected | copy or cut the whole line; pasting it with nothing selected puts it in above the caret's line, not into it |
| `Tab` / `⇧Tab` | with lines selected, every line a level in or out; `Tab` alone puts in one level |
| `Return` | the new line indented as the one before -- a level more after `{`, `[`, a start tag or a YAML `key:`, and between `{}` or `<a></a>` the closing one goes to a line of its own |
| `⌫` | in the spaces that indent a line, back to the level before; between `{}` both go |
| `⌘/` | Format ▸ Comment Lines: `#` in YAML and TOML, `<!-- -->` in XML, or back |

**Brackets and quotes close themselves** in JSON, XML, YAML and TOML: `{`, `[`
and `"` get their closing one, typing the closing one steps over it, and a `}`
typed first on its line takes the line a level out. Typed with something
selected, they go around it. Settings turns it off.

**Colours**: keys, strings, numbers, `true`/`false`/`null`, comments, tags and
attributes, worked out with the rest of the analysis. The bracket or tag that
goes with the one at the caret is shown on a tinted ground, with it.

**Structure emphasis** shades the lines of a structure around the caret: at 1
the smallest one it is in -- the array, the element, the mapping -- at 2 the one
around that, and so on, as the caret moves. An element is shaded from its `<`,
however many lines its start tag takes. Format ▸ **Increase Structure
Emphasis** (`⌥⌘↑`) and **Decrease Structure Emphasis** (`⌥⌘↓`) change the
level, and say what they change it to -- "Increase Structure Emphasis to 2".
The level is the window's own and goes when it closes; a new window starts at
0, none, up to 5 at most, both set in Settings.

**Go to Line** (`⌘G`) asks for a line and puts the caret at its start;
Return or Go jumps, Escape or Cancel does not. In the tree it selects the node
on that line, opening what holds it, and scrolls to it.

**The right-click menu** is Cut, Copy and Paste and the Format menu's items
that apply to the file, with their keys -- no fonts, spelling, substitutions,
services or Writing Tools. The tree's right-click menu ends with them too.

**The Format menu**, for the Text Edit window in front:

* **Format Document** (`⌥⌘L`) lays JSON and XML out again by Settings'
  indentation: keys keep their order, numbers and strings stay as written,
  comments and processing instructions stay. XML text that means something is
  left alone -- an element with text and elements mixed, or `xml:space="preserve"`,
  keeps what is inside it as it is. A file that breaks its format is not
  formatted: the alert says where, with **Show**. One Undo takes it back. YAML
  and TOML have nothing to format: their layout is their structure.
* **Compact JSON** puts it all on one line.
* **Comment Lines**, **Move Lines Up**, **Move Lines Down**, **Delete Lines**,
  **Increase** and **Decrease Structure Emphasis**. In the tree the two moves are **Move Up** and **Move Down**, and move the
  selected node.
* **Show as Tree** / **Show as Text** (`⌃⌘T`).
* **Add Child** (`⌃⌘N`) and **Add After** (`⌘↩`), in the tree: a node like
  the one next to it -- an element in XML, an attribute after an attribute --
  its name ready to type.
* **Show Type Column**, for the tree -- also on the right-click menu of the
  tree's column headers, as Hide Type Column when it is shown.

The menu is greyed out while no Text Edit window is in front.

**The tree** -- the button with the indented list in the bar, or `⌃⌘T` --
shows a JSON, XML, YAML or plist file as an outline of **Key** and **Value**, opened
on the node the caret is in. What a node is shows without a column of its own:
an element's name is blue, an attribute's is orange after an `@` badge, a
comment is `#comment`, a processing instruction `<?…?>`; a number is blue, a
boolean or null pink, and a container counts its keys, items or children. The
**Type** column is there for the asking -- Format ▸ Show Type Column, the
tree's right-click menu, or Settings -- and the name's tooltip says the type
anyway. A value over several lines shows on one, its breaks as `↩`. The
columns stay where they are: they cannot be dragged. With the text's line
numbers on, the gutter beside the rows gives the line each node starts on --
the same number on rows whose nodes share a line.
In it:

* **Double-click** a key or a value, or press **Return**, to edit it: a JSON or
  YAML key, an element's or an attribute's name -- its end tag follows -- a
  string, number or boolean, an attribute's value, an element's text, a comment.
  A JSON number must be a number; `yes`, `no`, `1`, `0` are taken for booleans.
  A value over several lines -- a comment, CDATA, text -- and the DOCTYPE and
  processing instructions are edited in a **text area** under the row, line
  breaks and all -- never in the row itself: **Done ⌘↩** keeps it, Escape
  leaves it. Its corner drags it larger, and the next one opens that size. Clicking elsewhere
  keeps what was typed, in a row as in the text area. The DOCTYPE and
  instructions are edited as written, `<!DOCTYPE …>` and `<?…?>` included;
  what would not read back as XML is not made.
  What is typed is written as the format needs it: quoted and escaped in JSON,
  `&lt;` and `&amp;` in XML, quoted in YAML only where it would not read back.
* **Right-click** for **Add Child** and **Add After** -- by type: String,
  Number, Boolean, Null, Object, Array in JSON; Element, Attribute, Text,
  Comment in XML; Value, Mapping, Sequence in YAML; the one `⌃⌘N` or `⌘↩`
  adds shows the key -- **Make Attribute** or **Make Element**, **Change
  Type**, **Duplicate**, **Delete**, **Edit in Text Area…**, **Copy XPath**,
  **Copy JSON Path**, **Copy YAML Path** or **Copy Key Path**, **Show in Text**,
  **Expand All**, **Collapse All** and **Show Type Column**. A new node's name or value is
  ready to type.
* **An element becomes an attribute**, and back, by its name: an attribute is
  edited as `@name`, so typing `@` before an element's name makes it an
  attribute of its parent -- `<name>Diptych</name>` becomes `name="Diptych"` --
  and taking the `@` away makes an attribute an element, first in its parent.
  An element can turn into an attribute when it holds only text and has no
  attributes, and its parent has no attribute of that name. An XML name never
  starts with `@`, so the badge can only mean an attribute.
* **Copy XPath**, **Copy JSON Path**, **Copy YAML Path** and, for a plist,
  **Copy Key Path** put the clicked node's path on the clipboard, as the
  format's tools write it: `/catalog/book[2]/@id` -- a position only where a
  name repeats -- `$.store.book[0]['the title']`, `yq`'s
  `.store.book[0]."the title"`, and PlistBuddy's `:CFBundleURLTypes:0`.
* **Delete** deletes the node.
* **Find** (`⌘F`) opens a bar over the rows: what is typed is looked for in
  the names and values, folded away or not, and the first match from the
  selected row is selected and opened up to. Return goes to the next, `⇧↩`
  to the one before, round from the end; the bar says which of how many.
  Escape or Done closes it.
* **`⇧⌘↑` and `⇧⌘↓`**, or `⌘↑` and `⌘↓`, move the selected node and all it
  holds to the next place in the structure, as Move Lines does with lines in
  the text: past the node next to it; into that node, at its near end, when it
  is an open container; out of its own container, before or after it, when it
  is at the end of it. Where it cannot go -- the top value, an element past an
  attribute -- it beeps.
* **Drag** a node to move it: between others, or onto one to go in at its end.
  Moved from an object to an array a key is left behind; from an array to an
  object it gets one. An attribute goes only among attributes.
* **Undo** (`⌘Z`) is the text's: every change in the tree is a change in the
  text, a move one step.

Only what a change is about changes in the text: the separators around it --
commas, the indentation its neighbours have, whether they share a line -- are
kept, and so are the comments and the layout of everything else. A file that
cannot be read as a tree says why, with the line, instead of the outline.
YAML is read as one document of mappings, sequences -- `- key: value` too --
and scalars, plain, quoted or in `|` and `>` blocks, after any `%YAML` and
`%TAG` directives; anchors, aliases and tags stay as written. A flow collection
with something in it, `[1, 2]`, is a value as written, on one line or over
several. Explicit `? key` entries and a second document are beyond the tree:
it names the line where it stopped.

**Property lists** (`.plist`) open as their tree: a dictionary's `<key>` and the
value after it are one node, named by the key, of type String, Integer, Real,
Boolean, Date, Data, Dictionary or Array. A value must be one of its type --
an integer, an ISO 8601 date, Base64 for data. The text is the plist's XML,
edited as XML is -- coloured, checked, folded. A **binary** plist is shown as
the XML it stands for, its dictionary keys in alphabetical order, the way the
conversion writes them. **Save** writes a plist as it came, binary or XML, and
the button beside it, **Save XML** or **Save Binary**, writes it the other way --
then that is how it is saved from then on. Binary is written only from text
that reads as a property list. Right-click a `.plist` file for **Plist Edit**.

**Settings ▸ Behaviour ▸ Text Edit** has the indentation for each format --
spaces or tabs, and how many; YAML is always spaces, as it must be -- and a
tab is shown as wide as that. Then whether brackets and quotes close
themselves and the XML end tags are put in, the structure emphasis -- how far
out it goes and where a new window starts -- and how Format Document lays the
text out: how many empty lines it keeps where there were some, a space before
the colon in JSON, arrays of plain values on one line, XML attributes each on a
line of their own, and `<br />` rather than `<br/>`.

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

## Previewing a property list

Quick Look shows an XML plist as its source and a binary one as a name and a
size. Both are rendered instead, through the same hook as `.DS_Store` and
Markdown: `PlistReport` reads the file with `PropertyListSerialization`, which
takes XML, binary and OpenStep alike, and lays it out as Text Edit's tree does
-- Key, Type and Value, one row each, dictionaries and arrays folding under
their keys with `<details>`, since Quick Look runs no script. An XML list is
read by `PlistTree`, the tree editor's own reader, so the keys stay in the
file's order; a binary one goes through its XML form first. The page is
written as `<name>.plist.html` in a folder of its own per path, because the
panel's title is the file name, and it stops at 5,000 rows.

The panel's keys belong to the pane behind it. A text, JSON or plist preview
puts a read-only text view in the panel, and the key router used to treat that
as a text field and leave the keys alone -- F2 beeped. And the panel floats:
F2 gives the keyboard back to the browser window with `makeKey`, not
`makeKeyAndOrderFront`, which brought the window over the preview.

## Previewing an old-style JPEG TIFF

Scanners and Microsoft Office Document Imaging wrote multi-page TIFFs whose
pages are "old-style JPEG", compression 6. ImageIO has never decoded those, so
Quick Look showed the thumbnail stored beside a page and then nothing. Each
page's directory does say where a complete JPEG of it sits in the file -- the
`JPEGInterchangeFormat` tag -- so `OldJPEGTiff` walks the directories, takes
those JPEGs out as they are, without decoding the TIFF, and the panel shows a
page with every one of them, one under the other, numbered. Any other TIFF is
left to Quick Look.

## Theme, font and zoom

Settings ▸ **Appearance** ▸ **Theme** sets whether Diptych's windows are light,
dark, or follow the Mac. Light and dark override the system setting, so a dark
Diptych can sit on a light desktop, or the other way round; *Follow the system*
leaves the Mac in charge. It applies to the whole window at once.

Settings ▸ **Appearance** also chooses the font the panes are drawn with, and the
size. `⌘+` and `⌘−` step it, `⌘0` returns to 11 pt. The range is 8–28 pt,
clamped on the way in as well, since `config.json` is meant to be hand-editable
and a size of `0` would leave no way back.

Only the **panes** follow it. Settings, the sidebar, dialogs and the function bar
keep their own sizes -- what is being configured is the file listing, not the
chrome around it. With a **Text Edit** window in front the same three commands,
and `⌘=`, size its text and tree instead: 13 pt to start with, 8–36 pt, kept in
Settings with the rest of Text Edit's.

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

**Rows can be put in an order of your own.** `⇧⌘↑` and `⇧⌘↓` move the selected
file, or files, one place up or down, past the row next to them -- by keyboard,
not by dragging, since a drag drops files into folders. The header's sort arrow
goes: the rows are in no column's order any more. The order is kept in memory
only, for the folder on screen. Clicking a column header sorts again, and going
to another folder -- or to the same one again -- forgets it. Folders stay above
files while Settings keeps them first, and `..` stays on top.

While the order is your own, a file that goes is simply gone from it, and a new
one goes where the sort would have put it among the rows you did not move: after
the last of them the sort puts before it -- after any other new files there that
sort before it -- or, with none before it, in front of the first one after it.
Rows you moved say nothing about where a new one belongs.

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
  again. Double-click a name, **Show**, or right-click ▸ **Show in Diptych** to
  see it in a pane; **Copy** puts every name found on the clipboard, one path
  a line; **Stop** ends a search early.
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

## Find Duplicates

**File ▸ Find Duplicates…**, right-click ▸ **Find Duplicates…**, or the
toolbar button (switched on in Settings ▸ Toolbar), with one item selected,
opens a window for it. Nothing is read until **Start**; **Stop** ends a search
early, and what was found stays. Closing the window stops the search too.

- **For a file**, it lists every file holding the same bytes, nearest first:
  its own folder, then the folders under it a level at a time. With **Search
  the whole volume**, then the folder above without the part already read,
  and so on up to the top of the volume -- on the startup disk that is `/`,
  the data volume only, `/System/Volumes` skipped since it is the same files
  again. Below them, **a checkbox for each other mounted volume**, all off:
  the ones ticked are searched after that, the same way, in the order listed
  -- the USB backup disk, say, and not the video server. The selected file is
  listed first.
- **A line above the progress says how wide the search has gone**: *Its own
  folder*, *Subfolders, a level at a time*, *Wider: everything under
  ~/Documents* -- one folder further up each time -- and *Another volume:
  "Backup"*. Stop it once it has gone wide enough; what was found stays, and
  the line says where it stopped.
- **For a folder**, it lists the files inside it that hold the same bytes, in
  groups -- with **Search in subfolders too**, a level at a time down the
  tree. Only files that share their size with another one are read, and each
  of them once.
- **Display links as duplicates** lists other names of the same file -- hard
  links -- and symbolic links leading to a file of the same content, marked as
  such. A link is followed: it is listed together with the file it leads to,
  wherever that file is, even outside what is searched -- and that file is not
  listed a second time when the search reaches it. Off, a second name of a file
  is left out, and links are not looked at.
  Empty files are never duplicates: every empty file is the same as every
  other.
- **Each file** is shown with its full path and the pane's marks: its icon, the
  link arrow and how far the link goes, the hard-link count, the executable
  mark. The Compare Folders letters say what sets it apart from the group's
  first file besides the bytes: **N**ame, **P**ermissions, e**X**tended
  attributes, **A**CL, **M**odified, **B**orn, **O**wner. A click on the path
  shows the file selected in its folder, in the active pane of the window the
  search came from.
- **Select the ones to throw away**, or a whole group with the box in its
  header. **Move Selected to Trash** stays greyed while every file of some
  group is selected, and a line above it says so and why: this is for keeping
  one of each, never for losing all of them. A symbolic link left unselected
  does not count as kept -- once its file is in the Trash it leads nowhere.
  Undo in the browser window puts them back.
- **A link left without its file is said, in purple.** When a listed symbolic
  link is not selected but the file it leads to -- or a link on its way there
  -- is, the button stays on, and a line above it names the link and where it
  leads. Two lines at most: a click on it, or on the orange one, opens a sheet
  with the whole list -- every link, and every file going to the Trash that
  they lead to.

## Disk Usage

**File ▸ Disk Usage…**, or the right-click menu on a folder, opens a window
showing what is taking up the room under it as a **heat map**: the folder's
immediate contents as rectangles sized by bytes, largest first, coloured on a
scale from cool (small) to hot (large) so the big things jump out at a glance.
Click a folder to go into it; the arrow at the top goes back up.

The picture fills in **as the scan runs** -- each top-level item is drawn the
moment it is measured, fading in, rather than hiding behind a spinner until the
whole folder is done. The scan itself runs off the main thread with a running
file count and a Stop, so the window stays responsive and the scan can always be
cancelled; **Scan again** re-reads from disk. Hover any rectangle for its full
path and size in the footer.

The layout is a squarified treemap (the Bruls/Huizing/van Wijk algorithm), areas
proportional to bytes and shapes kept near square. A symbolic link is a leaf,
never followed, so nothing is counted twice or walked out of the folder. The
geometry is in `Treemap` and the scan in `DiskUsage`, both tested on their own;
the window is `DiskUsageView`.

## Paste Special

**Edit ▸ Paste Special**, and on a right-click **Paste ▸** (under the Paste
submenu, which replaced the old top-level Paste Special), makes one property of
the copied file the same on every selected item: copy one file (⌘C, here or in
Finder), select the others, and choose what to take from it.

- **Permissions**, **Extended Attributes**, **Access Control List**,
  **Modified Date**, **Created Date**, **Owner**, **Group**, **Location** and
  **EXIF**. Extended attributes and the ACL are made *the same*: what the
  copied file has is set, what it lacks is taken away -- an ACL included. The
  attributes macOS keeps for itself, `com.apple.provenance`, are left, and so
  is a value no program may read.
- **Location** is the GPS fields alone; **EXIF** is every field, the location
  with it, except which way up the picture is and how big it is -- those
  belong to each picture. A field the copied picture lacks is taken out of
  the others. Both are greyed when the copied file has none, or when any
  selected file is not a JPEG or HEIC picture. Written the way the EXIF
  editor writes, without touching a pixel.
- **All of the Above** does every one of them. It works whatever the files
  are: the EXIF is copied only from a picture that has some, and only onto
  the selected pictures that can take it -- the rest get everything else.
- **Dates are copied to the nanosecond**, the way the file system keeps them,
  and Undo puts them back the same way: set through a `Date` they came out a
  few hundred nanoseconds off, and the two files still differed.
- **A modification date older than the creation date** takes the creation date
  back with it: macOS has no file changed before it was made. Undo puts both
  back.
- **Owner and group** are a plain `chown`: giving a file to somebody else takes
  an administrator, and what was refused is listed; Get Info's Change Owner…
  asks for the password.
- **One step in Undo**, whatever it took in -- *Undo Paste Permissions*,
  *Undo Paste Special*. A file already the same is left alone.

## Making a PDF of pictures

**Right-click ▸ Image ▸ Make PDF…** turns pictures into PDFs: a page for each
picture, and one for each page of a TIFF that has several.

- **One PDF for each picture, or one of them all**, in the order the pane lists
  them, under a name of your choosing; next to the pictures or in the other
  pane's folder.
- **The page is the picture's own size**, from its resolution -- an A4 page
  scanned at 300 ppi is an A4 page -- or **A4** or **US Letter**, turned to
  suit the picture, which is fitted in.
- **A JPEG goes in as it is.** Quartz writes a picture made from JPEG data
  as those bytes (`DCTDecode`), so nothing is compressed again and nothing is
  lost; other pictures go in without loss. A photo taken sideways is turned
  by the page, not by redrawing its pixels.
- **Old-style JPEG TIFFs** -- the ones Quick Look could only show as a
  thumbnail -- are read through the JPEG of each page, as the preview reads
  them: 22 pages of 2005 scans made a 22-page PDF in a fifth of a second, a
  little smaller than the TIFF.
- Undo moves the PDFs to the Trash.

## Optimize File Size

**File ▸ Optimize File Size…**, and on a right-click when a photo, PNG or PDF
is among the rows, makes them smaller -- several kinds at once. A window lists
every file with its size, the size it would have and what that saves, and
under the list the settings of each kind there is:

| Kind | How | Settings |
|---|---|---|
| **Photos** (JPEG, HEIC) | Encoded again by ImageIO, in the same format | Quality; the longest side, or the size kept; EXIF, location and the rest kept or not -- the turn that shows it upright always is |
| **PNG** | A palette, chosen by median cut, with Floyd–Steinberg dithering -- what pngquant does -- or written again without loss | At most 256, 128, 64 or 32 colours, or all of them; dithering |
| **PDF** | Saved through a Quartz filter of its own, the same kind as Preview's *Reduce File Size*, with the values chosen here | The pictures' quality, and the resolution they are brought down to |

- **The sizes are real.** Each file is optimized into a temporary folder of the
  window's own -- the selected one first, four at a time -- and made again
  when a setting of its kind changes. A file that would not get smaller is
  unticked, in orange; ticking and unticking by hand is kept.
- **Before and after.** The selected file is shown once, the original left of
  a line and the optimized one right of it; drag across the picture to move
  the line, and zoom to 100 % or 200 % to compare pixels. A PDF shows its
  pages, one at a time.
- **A PNG with transparency keeps its colours**: the palette here has no room
  for it, so it is written again without loss, and the row says so.
- **A PDF's text and drawings stay as they are**; only its pictures change.
  A signed PDF loses its signature, as it does in Preview.
- **What a PDF holds is said**: how many pictures, their resolution -- worked
  out from each picture's width and its page's, which is right for a scan --
  and how many are black and white. *Keep it* in the resolution menu names
  the resolution there is now.
- **A black-and-white scan is left as it is.** One bit per pixel, deflated or
  in CCITT or JBIG2, is already compact; the filter can only write JPEG,
  eight bits at least, and the file grew tenfold. Such a PDF, or one with no
  pictures, is listed with the reason and cannot be ticked -- as no row that
  would not get smaller can.
- **Pages go down**: the lower arrow of the page counter is the next page.
- **Replace the originals**, the default: each stays the same file -- its
  hard links, permissions, tags -- holding the smaller bytes, and keeps its
  modified date unless that is unticked. One step of Undo puts every one
  back. Or **save beside them** as `name (optimized).jpg`.
- To change the format -- PNG to JPEG, JPEG to HEIC -- use Image ▸
  Convert….

## Splitting and joining a file

**File ▸ Split File…**, or the right-click menu on a single file, cuts a file
into numbered parts -- `big.zip.001`, `big.zip.002`, … -- each no bigger than a
size you pick, so a file too large for a FAT volume, a disc or a mail attachment
goes across in pieces. The Split window is a real, **movable** window (not a
sheet), so it slides aside off the file list; it shows the file's size in
whatever unit the picker is on, and a line that names the parts it will make --
`…​.001` through `…​.NNN`, the count worked out live from the size you type. The
sizes people split for are ready to click (Email, CD, DVD, FAT32); sizes are
1024-based, so a 4 GB part fits under a FAT volume's 4 GiB limit.

Splitting **never overwrites**: if any of the part files (or the manifest) are
already there, it says which and does nothing. And because a mistyped size can
turn one file into thousands of tiny ones, a split into more than a set number
of parts (20 by default, in **Settings ▸ Behaviour**) asks you to confirm the
exact count first.

Beside the parts sits a small JSON **manifest** -- `big.zip.diptychsplit.json` --
listing every part with its size and SHA-512. It is pure extra: the parts still
join with `cat *` on Unix, `copy /B` on Windows, or an older Diptych. But with
it in hand, **Join Parts** notices a part gone missing or corrupted and refuses,
naming it, instead of quietly writing an unusable file.

**Join Parts** -- on the right-click menu and in File -- is offered whenever the
selection is a set of parts (select **any** of them, or all; they need only
belong to one file) or the manifest. It reads the parts in order and writes the
file back out, byte for byte; the parts are left in place. Without a manifest it
still catches a gap in the numbering (part 11 missing from 1…15); only a missing
*trailing* part cannot be noticed, since nothing then records how many there
were. A name already taken is stepped past (`big (2).zip`) rather than
overwritten. Both splitting and joining are a single [Undo](#undo-and-redo) step.

The parts go beside the file; when that pane is read-only -- a disk image, a
share mounted so -- they go in the other pane instead, and the Split window
says so. (If neither pane can be written to, Split and Join say that rather than
doing nothing.)

The streaming, the manifest and the verification are in `FileSplitting` (off the
main thread, tested on its own); what is selected, where the output goes and the
movable Split window are in `SplitActions` and `SplitView`.

## Archives

The **Archive** menu, the same on a right-click, and a toolbar button switched
on in Settings ▸ Toolbar (off by default).

**Create Archive…** opens a window listing everything selected, with the
format and what that format can keep. Each format is made by the tool macOS
has for it, called by its full path:

| Format | Made by | Options |
|---|---|---|
| **ZIP**, the default | `ditto -c -k`, as Finder's Compress; under a password `tar --format zip` | Mac data in a `__MACOSX` folder as Finder writes it (on by default), or the bytes and permissions only; compression none, fastest, normal or smallest; a password, AES-256 or ZipCrypto |
| **tar** | `/usr/bin/tar` (libarchive) | gzip, bzip2, xz or none; extended attributes, ACLs and file flags or not; owners as names and numbers, numbers only, or root and wheel |
| **Apple Archive** (`.aar`, `.aea` encrypted) | `aa archive`, encrypted by `aea encrypt` | LZFSE, LZMA, zlib, LZ4 or none; owners and groups, extended attributes, ACLs each kept or not; a password |
| **Disk Image** (`.dmg`) | `hdiutil create`, `attach`, `ditto`, `convert` | compressed LZFSE, zlib or LZMA, read-only, or read/write; APFS or Mac OS Extended; AES-128 or AES-256 under a password |
| **ISO** (`.iso`) | `hdiutil makehybrid` | ISO 9660, Joliet and UDF, ISO 9660 and Joliet only, or UDF only |

- **The name** is the item's for one, *Archive* for several, numbered when it
  is taken -- *Archive 2.tar.gz*. It goes next to the items, or into the
  other pane's folder.
- **Several items** sit side by side at the top of the archive. ditto and aa
  take one folder, so they are given a folder of clones -- free on APFS.
  Items from a flat view, from several folders, go in together; two of the
  same name are refused.
- **Nothing half-made shows.** The archive is written under a hidden name and
  renamed when complete; **Stop** leaves nothing behind.
- **A bar, how much of how much, and the time left.** What goes in is counted
  first; then each tool says how far it has got. `ditto -V` writes a line as
  it starts each file and its size when done; `tar -v` writes the name as it
  starts a file and ends the line when done. Inside one big file, the tool's
  read position is read through libproc, as `lsof` sees it, so a 10 GB file
  moves the bar too. aa says nothing as it goes, so it archives uncompressed
  into a second aa that compresses -- `aa archive -a raw | aa convert` -- and
  the bytes passing between them are counted.
- A zip always records each item's owner and group, as numbers: ditto writes
  them in an old Info-ZIP field, and no option leaves them out.
- What was chosen last is offered next time -- never a password. Undo moves
  the archive to the Trash.

**Under a password.** The password is typed twice in the window and handed to
the tool in a file only you can read, in a folder only you can enter, removed
when the tool is done -- never on its command line, where `ps` shows it to
every user of the Mac.

- **A zip** is written by tar, as ditto cannot encrypt: the bytes and the
  permissions, no `__MACOSX`. **AES-256** (WinZip's) is strong, and opened by
  7-Zip, Keka, The Unarchiver and Windows 11 but not by Archive Utility.
  **ZipCrypto** is the original scheme: Finder, Windows and every unzip open
  it, and so does anyone who tries for a few minutes with a free tool -- it
  keeps out someone glancing, not someone trying.
- **An Apple Encrypted Archive** (`.aea`) is AES-256 with an scrypt-derived
  key, opened by Archive Utility on macOS 13 and later. `aea` refuses a
  password shorter than 20 characters, and the window says so first.
- **A disk image** is encrypted by `hdiutil convert -encryption`, and asks for
  its password when mounted, as any encrypted image does.

**Disk images.** A `.dmg` is made the way `build.sh` makes Diptych's own: an
empty image sized for what goes in, attached out of sight, the items copied in
with `ditto -V` -- attributes, tags and ACLs kept, a line per file for the bar
-- detached, and converted to the format chosen, with hdiutil's own percent
shown. `hdiutil create -srcfolder` would do it in one go, and fails as a whole
with nothing but "Resource busy" when any step is unhappy. An `.iso` is
`hdiutil makehybrid` of the items in a folder of clones; it cannot be
encrypted, keeps no Mac attributes, and its bar is the image's size as it is
written.

**Extract Here** puts what is in the archive next to it; **Extract to Other
Pane** into the other pane's folder. zip (and jar, war, ipa), tar compressed
or not (`.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`…), `.aar` and `.aea`.

- **An encrypted archive asks for its password**, and again while it is
  wrong. A zip is encrypted when an entry in its central directory says so;
  its password is checked by Diptych first -- WinZip AES keeps two bytes
  derived with the key, ZipCrypto a byte of the file's CRC at the end of its
  12-byte header -- because tar, given a wrong one, asks for another ten
  thousand times and takes a quarter of a minute to say so. tar then unpacks
  it, reading the password on its standard input; `aea decrypt` unpacks an
  `.aea` into `aa extract`.

- **One item at the top** comes out as itself, numbered if the name is taken.
  **Several** come out in a new folder named after the archive, as Archive
  Utility does it.
- **First as you.** The archive is unpacked into a temporary folder on the
  same volume -- `ditto -x -k`, `tar -xp`, `aa extract` -- so the files are
  yours, in the groups you belong to. Then what the archive records is read
  (tar's mtree listing, which reads the uid and gid a zip holds, or aa's JSON
  listing) and compared with what came out.
- **When the archive records more** -- another owner, a group you are not in,
  a setuid, setgid or sticky bit the tool dropped (ditto drops all three) --
  Diptych says so, item counts by owner and group, and asks: **Extract Without
  Them**, **Restore as Administrator…** or **Cancel**.
- **Restore as Administrator** asks macOS for the password once and runs a
  script as root: the archive is copied into a folder only root can enter,
  must still have the SHA-256 it had when it was read, is unpacked there, each
  owner, group and mode is set from what was listed -- written into the
  script, not read from a file the user could change in between -- and the
  result is moved into place. Cancelling the password extracts as you.
- **A downloaded archive's quarantine** goes onto everything that comes out
  of it, as Archive Utility does.
- Undo moves what was extracted to the Trash.

### An archive opened as a folder

**Return** on a zip, tar or Apple Archive -- or **Archive ▸ Open as Folder**,
whatever Settings says -- shows what is in it in the pane, as a folder.

- It is **unpacked once**, as you, into a folder named after the archive in
  Diptych's caches, with a bar of how far, and Stop. A zip's bar is ditto's
  line per file; a tar or an Apple Archive is read through a pipe, and the
  bytes passed are the progress. What it holds is listed first, and refused
  when it is more than the disk has free.
- **Everything that works on files works inside it**: Quick Look, Compare,
  Copy and drag out, the flat view, Find Duplicates.
- **Read-only.** The folder counts as a read-only volume, named after the
  archive: Rename, Move, Trash, New Folder and drops are greyed or refused,
  and the agent's batch operations skip anything inside it. The unpacked files
  are locked on disk too -- directories unwritable, files `r--` -- so not even
  another app can save over the copy. Extract it, or copy a file out, to
  change it.
- **The listing is the archive's, not the copy's.** Beside the files in each
  folder sits a small manifest -- `__DIPTYCH.json`, or `__1DIPTYCH.json` and
  on up where the archive itself has a file of that name -- holding what the
  archive recorded: the permissions, owner and group the extracted copy could
  not keep, such as a setuid bit or a group you are not in. The pane shows
  those, read from the manifest, over the real names and sizes on disk. The
  manifest is hidden -- it is not listed, and Quick Look of a folder inside
  the archive does not show it.
- **A copy out is an extract.** Copy or drag a file, or a whole folder, out of
  the archive and it lands with the archive's own permissions -- the write
  bits and any setuid, setgid or sticky bit restored, not the read-only lock
  -- and the archive's quarantine, owned by you, exactly as Extract gives it.
- **The path bar names it inside the archive** --
  `~/Downloads/photos.zip/2024` -- and typing or Option-clicking such a path
  goes there. Up from its top lands next to the archive, with the archive
  selected.
- Opened again while it has not changed, it is shown at once; changed, it is
  unpacked again. Everything unpacked goes when Diptych quits, and anything a
  crash left when it starts. A pane left inside one is saved as next to it.
- An encrypted one asks for its password; a downloaded one's quarantine goes
  on everything in it.

**A disk image** -- `.dmg`, `.iso`, `.cdr`, `.sparseimage` -- is mounted
instead, as a double-click in Finder mounts it, asking for the password of an
encrypted one, and the pane goes to its volume. It is in the sidebar with the
other disks, and ejected from there.

Off in **Settings ▸ Behaviour**, Return opens them as Finder would; **Open as
Folder** -- **Mount in Pane** for an image -- does it either way.

### Recovering a ZIP password

**Archive ▸ Recover ZIP Password…**, the same on a right-click, and a
**Recover Password…** button that appears on the password prompt once a typed
password is refused -- for a single selected `.zip`. The two of us have each
had a zip arrive whose password the sender read out wrong by a letter, and an
old archive turn up whose password was long forgotten. (The prompt also says,
when a password is wrong, that there is no limit on how many you may try and
nothing locks you out -- it is not signing in to a service.) It tries passwords
against the zip until one opens it, two ways:

- **From a password you remember.** You type it as you recall it, even if a
  letter or two is off, and candidates radiate outward from it by a *keyboard*
  edit distance: the guess itself first, then a neighbouring key struck in its
  place, a letter's case wrong, two keys swapped, one doubled or dropped -- the
  nearest first, farther and farther after. A sender's slip or a shaky memory
  is usually a key or two away, found long before a blind search would reach
  it. Diptych does not know of another tool that starts from a guess this way.
- **Brute force.** Every string up to a length you set, over an alphabet you
  pick -- digits, letters, letters and digits, or everything typable. The
  search space and the time it would take **on this Mac** are worked out and
  shown *first*, because past a short password the honest answer is "not in
  your lifetime", and the window says so in orange rather than letting you
  start a search that cannot finish.

The password is checked by the same two-byte (AES) or one-byte (ZipCrypto)
verifier Extract uses, so millions of ZipCrypto guesses a second are possible
without unpacking anything; a guess that passes the quick check is then
confirmed by actually decrypting, so a one-in-256 ZipCrypto false positive is
never reported as the answer. Found, the password is shown with **Copy**. The
search runs on every core and **Stop** ends it.

- **AES is slow by design.** A WinZip-AES zip runs a thousand-round key
  derivation per guess, so brute force reaches only short passwords; the window
  says as much and steers you to the guess instead.
- **This is lawful on your own archives**, or ones you were given leave to
  open, and may be a crime used on someone else's. The window says so plainly,
  every time.
- **For a long or truly unknown password**, the window points at the GPU tools
  that do this in earnest -- hashcat (modes 13600, 17200/17210/17225) and John
  the Ripper (`zip2john`) -- which run the search on the graphics card at
  millions to billions of guesses a second, orders of magnitude past any CPU.
  Diptych's search is the CPU, and meant for a password nearly right.

## The menu bar

**File**, **Edit**, **View**, **Go**, **Archive**, **Checksum**, **Window**,
**Help** -- Finder's arrangement, with Archive and Checksum added, and for the
same reason. There used to be a `Files` menu alongside `File`, which was a
coin toss every time: the two names say nothing about which holds what.

The split is Finder's: what you do *to* an item is in **File** -- Open, Get Info,
Rename, Copy and Move to Other Pane, the ownership and permission commands, Move
to Trash, Reveal in Finder, Open Terminal Here. Where you *go* is in **Go** --
Back, Forward, Enclosing Folder, and the two ways into the path bar.

Open stays in File even though Enclosing Folder is in Go, which looks odd
written down and is exactly what Finder does; following it beats inventing a
third arrangement for people to learn.

**With no browser window in front** -- Text Edit, Info, a comparison -- what acts
on panes is greyed out: File's commands on files, all of Go, and View's except
the text sizes, which then size Text Edit's text. **Format** is greyed out
everywhere but in Text Edit. A greyed-out item leaves its keys to the window in
front, so `⌘↑` and `⌘↓` move to the start and end of the text there, and `⌘⌫`
and `⇧⌘↑` reach Text Edit's own line commands.

**Right-clicking the empty space below a pane's rows** gives what you can do
*here* rather than to a file: **New** (Folder, File, from Clipboard), the
**Scripts** that take no items, **Paste** (Paste, as Link), Rename Many…, Select
All and Refresh. It is an `NSMenu` put up
by `FolderMenu`, because SwiftUI's `Table` consults its context menu only for
rows -- right-clicking below the listing used to show nothing at all. AppKit
will not let one item both paste on a click and open a submenu, so here the
paste sits inside the Paste submenu rather than on it; ⌘V pastes directly
either way.

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

Three commands in the File menu, shown only when the folder is actually tracked:
**Send My Work** (⇧⌘S), **Get the Latest** (⇧⌘D) and **Check for Changes**
(⇧⌘K). Right-clicking a file Git does not know about offers **Track This File**
and **Never Track This**; right-clicking one it does know offers **Stop
Tracking This File**.

- **Check for Changes** asks the shared copy what it has -- a `fetch`, which
  touches no file in the folder -- and says how many changes you are behind, or
  *Nothing new -- you are up to date*. Files someone else has changed as well
  turn red. It is the only command that reaches the network without being
  part of a send or a get, so it never runs on a timer; Settings ▸ Version
  Tracking can run it once per folder when Diptych first opens a tracked
  folder with changes in it.
- **Stop Tracking** asks first, then removes the file from version tracking
  (`git rm --cached`) and leaves it on this Mac. That is a change like any
  other, so it waits in your next send -- and once sent, everyone else loses
  their copy the next time they get the latest.

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
Extension, Permissions, Owner, Group, Tags (the Finder tags) -- and, read from
pictures and videos themselves: Format, Date Taken, Date Digitized, Camera,
Lens, Software, Artist, Copyright, Description, ISO, Aperture, Shutter, Focal
Length, Focal Length (35mm), Dimensions, Megapixels, Duration, Location,
Altitude (in metres or feet, as the Mac's region measures), City, State,
Country and Rating. They are off unless switched on. Each reads the header of
every picture and video in the folder, once while the file stays as it is,
which takes a moment in a big folder; other files leave them empty.

**In the pane itself** the same settings are at hand: drag a column header left
or right to move the column -- Name stays first -- and right-click a header for
every column in its order, ticked when shown, to show or hide one. A column
with nothing in it for any row of that pane is greyed there -- still there to
tick. What a hidden column would show is read from the files for that, for
under half a second; a column not settled in that time is not greyed. Both
change the settings, are kept, and every pane follows.

Column widths are remembered too, in `columnWidths`. SwiftUI's own
`TableColumnCustomization` records widths but -- measured, not assumed -- never
restores them for columns built with `TableColumnForEach`, so the widths are
stored as plain numbers and applied to the NSTableColumns underneath.

Settings live in `~/.diptych/config.json`, separate from session state. Only the
resource keys the enabled columns need are prefetched, so leaving Permissions or
Tags switched off costs nothing per row.

Adding a column means adding a case to `FileColumn`: the settings list is built
from `allCases` (less `originalLocation`, which belongs to the [Trash
listing](#trash-listing) alone), the loader asks each enabled case which
`URLResourceKey`s it needs, and the table and comparator switch on it.

### Right-click menu entries

The many file tools have grown the right-click menu, so the **Menus** tab in
Settings switches individual entries off to keep it short: Get Info, Find
Sibling Names, Find Duplicates, Previous Versions, Disk Usage, Archive,
Checksum, Split/Join, Optimize, the Image and Video tools, Run, Text/Bin Edit
and Scripts. Everything is on by default, and the core -- Open, Copy, Cut,
Paste, New, Rename, Move to Trash -- is never in the list, so the menu can never
lose what a file manager needs.

**Presets** set a whole group at once: *Everything* (the default), *Developer*
(the checksums, split/join, siblings, text and hex editors, scripts; the picture
and video tools off), *Content Creator* (the image, video and optimize tools;
the developer ones off) and *Minimal*. A preset shows its set and hides the
rest; individual ticks then adjust it. The switches are `MenuItem` cases and the
groups `MenuPreset`; what is off is kept in `hiddenMenuItems`, so a tool added to
Diptych later is on until you turn it off.

### What a copy keeps

Settings ▸ Behaviour ▸ **Copying** decides what a copy takes along besides its
contents. Out of the box it is everything, as Finder does it:

| | Kept (default) | Or |
|---|---|---|
| Created date | the original's, to the nanosecond | the time of the copy |
| Modified date | the original's, to the nanosecond | the time of the copy |
| Permissions | the original's | a new file's, 0666 less the umask (a folder 0777); or ones set for files and for folders |
| Group | the original's | the target folder's, when that folder has the setgid bit |
| Extended attributes | all of them | none |
| Access control list | the original's | none |

It applies to every copy: Copy and Paste, a drag, and an agent's batch copy,
and to everything inside a copied folder. A move keeps everything whatever is
set here, since it is the same file somewhere else. So does a sync in Compare
Folders, whose job is to make both sides the same.

- **Set permissions** are edited with the same grid as in the panes, one for
  files and one for folders, the octal value beside each: r, w and x set a bit
  in the triple the caret is in, Shift clears and Option toggles it, s sets
  setuid or setgid and t the sticky bit. All twelve bits are set as shown, on
  files and folders alike, whether macOS makes use of them there or not. A
  link has no permissions of its own and is left alone. config.json keeps them
  in `ls` form, `filePermissions` and `folderPermissions`.
- **The group** is the original's where you belong to it. Chosen instead, a
  copy put in a folder with the setgid bit takes that folder's group, and so
  does everything inside a copied folder that has it, as on Linux. Changing a
  file's group makes macOS clear its setuid and setgid bits; when the
  permissions are to be the original's, they are put back.
- **Without extended attributes** the copy loses its Finder tags, comment and
  colour label. The quarantine mark of a downloaded file stays regardless:
  removing it would let a downloaded program run unchecked just because it
  was copied. Whatever macOS keeps for itself and lets nobody remove stays too.
- **EXIF data and a picture's location** have no setting. They are part of the
  file's contents, so a copy always has them; Paste Special and the EXIF editor
  change them on a file.

An agent can change the same settings with `set_setting`: `copyCreatedDate`,
`copyModifiedDate` (`original`, `now`), `copyPermissions` (`original`,
`umask`, `fixed`), `copyFilePermissions`, `copyFolderPermissions`, `copyGroup`
(`original`, `setgid`), `copyExtendedAttributes` and `copyAccessControlList`.

## Checking for updates

**Diptych ▸ Check for Updates…** asks GitHub for the latest release and says
what it found -- a newer version, *you are up to date*, or that GitHub could not
be reached. A newer version offers **Download and Install**, which downloads the
disk image to `~/Downloads`, opens it and quits, or **Later**.

Settings ▸ Behaviour ▸ *Check for updates* decides whether Diptych looks by
itself: **At startup, once a day at most**, **Ask at startup**, or **Never on
its own**. Until that question has been answered once, nothing reaches the
network at startup. Only the question goes to GitHub, and nothing is downloaded
without asking; the menu command looks whenever you ask, whatever is chosen.

## Directory sizes

**View ▸ Calculate Directory Sizes** works out how much is in every folder in
the active pane, everything under it counted, and shows it in the Size column.
Greyed while the Size column is hidden, since that is where the totals go. The
toolbar can have it too, as **∑**, switched on in Settings ▸ Toolbar; it is off
by default.

- **Colours**: a total worked out is **teal**, a colour no other value in the
  pane uses, so it is not taken for a file's size. One about to change -- the
  total from before while it is worked out again, or one still growing -- is
  **orange**. `??` is a folder asked for that nothing is known about yet.
- **An estimate, early**: a folder shows a total as soon as its own files are
  counted, and it grows as the folders in it are read. A folder already known
  counts at what it was until it has been read again; whenever a folder's total
  changes, every folder above it changes by as much.
- **In the background**: it goes on while the pane goes elsewhere, and the
  totals are there when it comes back. They are kept in memory only, for as
  long as Diptych runs. The Info window of a folder shows the same total, and
  follows it.
- **One at a time**: one reader per volume, so two calculations never compete
  for a disk; asking again while one is under way queues behind it. A volume
  mounted inside a folder, and the targets of links, are not counted. Sizes
  are the files' own lengths, as the Size column shows files.
- **Sorted by Size**, a folder goes by its total as far as it is worked out,
  so while a calculation runs the rows move as the totals grow.
- **View ▸ Clear Directory Sizes** forgets every total and stops what is
  being worked out; the folders show `--` again, here and in the Info window.

## Values edited in place

Click a cell of an already-selected row, as for a name, and its value becomes
a field to type over; Return sets it for every selected item it can be set
for, Escape leaves it as it was. Each change is one step of Undo.

| Column | What is changed |
| --- | --- |
| Date Modified, Date Created | the file's own dates, for any file or folder |
| Date Taken, Date Digitized | the EXIF dates of a JPEG or HEIC; Date Taken is a QuickTime or MP4 video's creation date too |
| Lens, ISO, Aperture, Shutter, Focal Length, Focal Length (35mm) | a JPEG's or HEIC's EXIF |
| Software, Artist, Copyright, Description | a JPEG's or HEIC's EXIF, or a QuickTime or MP4 video's metadata |

- **Dates** are typed `2024-07-14 18:30`, seconds and an offset (`+02:00`) as
  you like; a picture's offset goes into its time-zone field beside the date.
- **Numbers as the column shows them**: `f/2.8` or `2.8`, `1/250 s` or
  `1/250`, `24 mm` or `24`.
- **Emptied, a value is removed.**
- Camera is Make and Model together, and City, State and Country may come
  from the towns list, so those are edited in the EXIF or video editor.

## Editing video metadata

**Right-click ▸ Video ▸ Edit Metadata…** on one or more QuickTime (`.mov`) or
MP4 (`.mp4`, `.m4v`) videos opens the EXIF editor on them: the same window,
working the same way, with a video's fields -- Description, Title, Artist,
Copyright, Camera Make and Model, Software; Date Taken with its time zone,
picked as a picture's are; and the location in the same four fields, going
round the three ways of writing coordinates, with a place pasted from a map
filling them all, and the map below. **Copy and Paste as JSON** work here
too.

- **Nothing is encoded again**: AVFoundation copies the picture and sound as
  they are into a new container, and the file is written in place, so it stays
  the same file. Undo puts each video back exactly as it was.
- **No camera where there is no place for one**: AVFoundation writes no make
  or model into an MP4, so the camera fields are there only when one of the
  videos is a QuickTime movie, or already has one.
- Other video formats -- AVI, MKV, WebM -- cannot be written.

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

Diptych's **own** *Reveal in Finder* is the exception, and goes to the real
Finder even while this setting is on -- otherwise it would open another
Diptych. It tells Finder by name (an Apple event) rather than routing through
the file-viewer default, so everything else opens Diptych while Diptych itself
still reaches Finder. If Finder cannot be scripted, it falls back to the system
file viewer.

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
every write. Settings ▸ Agents shows the token hidden, as
`••••••••-••••-••••-••••-••••••••••••`, with an eye to show it and a copy
button beside it (and one beside the port). The field can be edited -- typed
or pasted, a token from another agent's configuration say -- and takes only a
UUID: anything else turns red and is let go when the field is left. Clicking
into it while hidden starts it empty, so editing reveals nothing. **Regenerate**
writes a fresh one and
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
| `list_windows` | Every open window: browser windows with each pane's directory, the active side, and whether it is in single-pane mode (only the active pane shown), plus Info / Compare / Bin Edit / Text Edit / Rename Many / EXIF / Settings windows with what each is showing |
| `get_pane` | A pane's current directory and listing; for a flat view, its expression and whether its walk is still collecting |
| `get_selection` | The files currently selected in a pane |
| `get_text_diff` | What an open Compare (file diff) window is comparing, whether it's a byte comparison, which side (if any) is unlocked for editing, and whether it has unsaved edits |
| `get_directory_diff` | What an open Compare Folders window is comparing: the two roots, the options results on screen were actually produced with, and the rename pairs diptych's own content-matching found |
| `select_items` | Replaces a pane's selection with given paths, visibly, in the GUI |
| `set_active_pane` | Makes a window's left or right pane the focused one |
| `open_diff` | Opens a Compare or Compare Folders window on two explicit paths; for two folders, the comparison options (permissions, ACL, attributes, dates, ownership, hidden recursion) can be set explicitly, and for two files, so can `ignoreWhitespace`/`wraps` -- reopening a pair already open updates that window instead of refusing |
| `open_info_window` | Opens the Info window for one explicit path |
| `open_exif_editor` | Opens the EXIF editor on explicit JPEG/HEIC paths, which may be in different folders -- something a right-click on one pane's selection cannot do. Nothing is written by the tool: you edit, tick and save (or cancel) in the window, and a save is one EXIF Change in Undo. A path that is missing, a folder, or another kind of file is reported, and then nothing is opened |
| `list_settings` | A curated, scalar subset of Settings an agent can read: version tracking, scripts, Apple Intelligence, startup tips, sounds, sort order, name suggestion style, Compare Folders defaults, what a copy keeps, the update-check preference, and more -- not layout things (columns, toolbar, favourites) or MCP's own enable/port |
| `set_setting` | Changes one setting by key, from `list_settings` |
| `show_flat_view` | Turns a pane into a [flat view](#flat-view) of a folder with an expression, and returns at once as the walk starts, with the expression's warnings -- so "list every image under here that the group can read" is shown in the pane, not just answered. A syntax error comes back with its position; `off: true` goes back to the folder. `get_pane` lists the rows found so far, says the pane is flat and with which expression, and -- while the walk is still collecting -- `flatProgress`: how many found, how many folders read, and the one being read; also whether it was stopped, is stale, or skipped unreadable folders |
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
  stay light or dark, are one of the two **VT100** phosphor schemes (green or
  amber on black, the 1970s video terminals), or are chosen -- in Settings ▸
  Appearance. Option types what your keyboard layout puts on it (`#`, `@`,
  `\`…), as in Terminal.app; *Use Option as Meta key* there makes it the
  shell's Meta instead.
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
permissions, owner/group, modification and creation time, symbolic link, new
folder, new file (empty, or with the text given), **extended attributes** (set
one, in text, hex or base64, or remove one) and **Finder tags** (add, remove, or
set the whole list).

**On an SFTP server** the tools report and take `sftp://user@host/path`
addresses; a server's own absolute path is understood too, when one connected
server has it listed. Rename, permanent delete, permissions, owner/group (by
the server's names or numbers), modification time, new folder, new file, and
copy or move to and from the server work there; the others are refused for
server items, since SFTP has no Trash, tags, attributes or links to make.

In the review window:

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

`copyfile` does not keep the creation date: it sets the modification date, and
the copy is left created at the moment of the copy -- or at the modification
date, when that is older. Once the copy is done, the creation dates of the
file, or of everything in the folder, are set from the originals with
`setattrlist`, to the nanosecond. Foundation's `copyItem`, used where nothing
reports progress, keeps a file's creation date but not a folder's, so the same
is done after it. What Settings ▸ Behaviour ▸ Copying then leaves out (see
*What a copy keeps*) is taken off the finished copy.

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
list of what is waiting -- "Copy “a.mov”, “b.mov” and 3 more to “Films”" --
with an estimate for all of it once the running one has a speed. Before that it
looked exactly like nothing happening, until the second operation began minutes
later of its own accord.

**The same transfer is not queued twice.** An item already waiting to be moved,
or being moved, is not moved again -- it can only leave once -- and one waiting
to be copied to a folder is not copied there again: a folder grabbed three times
in a row is one move. *Already being moved* or *Already being copied there* says
so; the rest of a request that repeats only part of one goes ahead.

The panes are reloaded **and awaited** at the end of each transfer, not fired and
forgotten. The next transfer in the chain starts the moment the previous one
returns, and an un-awaited reload was queued behind it -- so a moved item sat
visibly in the source pane until an unrelated copy had finished. The wait is
three seconds at most: a server that has stopped answering would otherwise hold
the next transfer for ever. The panel goes as soon as the copying is done, before
the panes are listed, and its **×** hides it at any time -- the transfer goes on.

The panel is an **overlay**, not a sheet. Only one presentation modifier per view
is reliable here, a clash dialog has to be able to appear *during* a transfer,
and an overlay leaves the panes visible while you watch.

## Drag and drop

Drag rows between the panes, out to Finder or any app that takes files, and
between separate Diptych windows -- all the same mechanism, since what leaves
the pane is a real file reference rather than a URL string.

The drop rule follows Finder: within one volume a drag **moves**, across volumes
it **copies**. Hold `⌥` to force a copy, `⌘` to force a move. Dropping items back
into the folder they already live in does nothing: the drop is reported as
failed, so AppKit slides the drag image back to where it started, and *Already
in "folder"* says why.

**A drag that never left a 40-point circle around where it began, within its
own pane, is a click.** A name clicked, or clicked several times, often drags a
few points with it -- and that drag could rest on the folder row next door, or
hold long enough for spring-loading to open a folder, and then drop: a move
nobody asked for. Where the share could not be written to it came up as a
permission error out of nowhere; where it could, the move happened. Such a drag
now neither drops nor spring-loads. A drag that went further and came back --
to the row next door, say -- is a drag, since the farthest point it reached is
what counts.

A folder dropped **onto itself, or into a folder inside it**, stays where it is
too. Nudged a few points, a folder lands on its own row -- a folder, so a place
to drop into -- and that started a move of the folder into itself, which on a
server first spent a while measuring it before failing. It slides home now, as a
file does, and said deliberately the answer is *A folder cannot go into itself*.

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
second window. Each tab applies on its own -- there is no global Save, because
the operations behind them are separate syscalls that fail independently and a
half-applied Save is worse than none.

| Tab | Holds |
| --- | --- |
| General | location (read-only), name (rename in place), kind, size, and the created / modified dates, which are editable. "Added" and "Accessed" are shown but not settable -- the first belongs to the folder's index, the second to the kernel |
| Ownership | owner and group pickers (for a symlink these are the *target's*, since that is what changing them affects), the setuid/setgid/sticky checkboxes, and the nine permission bits as checkboxes with the octal mode |
| Tags | the seven colours Finder gives a dot, plus free-form tags |
| Attributes | every extended attribute -- what `xattr` shows. Text values are editable, binary ones (plists, bookmarks) are shown as hex and can only be removed, since saving them as text would corrupt them |
| Access | the access control list as text -- the same form `ls -le` prints and `acl_from_text` accepts. Empty it to remove the list |
| Signature | the code signature and what Gatekeeper makes of it -- see below |
| Open Using | the apps that can open the file -- open it in one, or set the default for its kind -- see below |
| Share | the system share sheet (Mail, Messages, AirDrop, Notes, …) for the file |

The Signature, Open Using, Share and [Details](#details--what-a-file-says-about-itself) /
[Open By](#open-by--what-has-a-file-open) tabs are read when first shown, not
when the window opens, because each is work the window is usually not about.

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
button too, which, like `⌘R`, lists the active pane again -- not both: the other
may be on a server, where listing it is not free.

The spinner in the path bar shows only for a listing that takes more than half
a second, and has a place of its own whether it spins or not. It used to make
the bar taller while it showed, so the rows jumped down and back on every
Refresh.

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
  photograph's location is visible rather than merely present. The place, as
  latitude and longitude, is a link that opens it in Google Maps, as is a
  video's Location.
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

Each new tab widens the window's minimum, because at too narrow a width macOS
puts the **whole tab bar** into a "more toolbar items" pop-up where no tab can
be chosen at all -- the same trap the Settings window fell into when it gained a
tab. Ten tabs need 1180, verified through accessibility: every tab button in the
bar, not one pop-up.

## Signature — code signature and notarization

The **Signature** tab reads what `codesign`, `spctl` and `stapler` say about a
file and gathers it into one answer: whether it is signed, whether the signature
verifies, the identifier, team and certificate chain, and what Gatekeeper makes
of it -- accepted or rejected, the `source` (`Notarized Developer ID`, `Apple
System`, …), and whether a notarization ticket is stapled. A headline line sums
it up (*"Signed and notarized by Apple"*, *"Ad-hoc signed"*, *"not
code-signed"*), and the tools' own output is under a disclosure. It is read-only
-- it inspects, it does not sign -- and runs the tools off the main thread when
the tab is first shown, with **Check Again** to run them afresh. The gathering
is in `CodeSigning`.

## Open Using — the apps that can open a file

The **Open Using** tab lists every app LaunchServices knows can open the file,
the current default marked, each with its icon and path. **Open** opens the file
in that app without changing anything; **Set as Default** makes it the default
for files of this *kind* -- every file of the kind, not just this one, which the
tab says plainly. It is `OpenWith`, over `NSWorkspace`.

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

The editor is the one in the key window, not the pane's: text selected in an
error, a warning or any other window copies with `⌘C` as text, never as the
files selected behind it -- in an alert too, where `⌘C` and `⌘A` work on its
text.

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

## Scripts of your own

Someone who writes shell scripts can put them in **`~/.diptych/scripts`**, and
they appear as menu commands -- **File ▸ Scripts ▸** and **Right-click ▸
Scripts ▸** -- for whoever uses that Mac. **Off by default**: Settings ▸
Behaviour ▸ *Run the scripts in ~/.diptych/scripts*. The menu is absent, not
greyed, when scripts are off or none of them suits what is selected.

**File ▸ Get Scripts…** -- also a button under the setting -- lists the scripts
that come with Diptych: making a zip, showing every detail `ls` knows, the two
that make a script editable and read-only again, and one that shows what a
script sees. Tick the ones you want; **Show Source** shows one in full, and
**Compare with Yours** opens the two-file comparison when something of that name
is already installed. They are inside the application, signed with it, so
**nothing is downloaded**. Installing writes each as `r--------`, owned by you,
so it passes every rule below; a file already there under that name goes to the
Trash first. Each still asks before it first runs. How scripts could also come
from GitHub, signed, is designed in [script-distribution.md](script-distribution.md).

This is not **Run ▸**. Run ▸ runs a program you right-clicked, with arguments
you type; Scripts ▸ runs a script from that folder *on* what you right-clicked,
with no typing at all.

**A script says when it applies** in comment lines after the shebang, up to the
first line that is not a comment:

```sh
#!/bin/sh
# name: Make a zip of these
# description: Puts what is selected into untitled.zip, beside it.
# apply-to: path != "*/.git/*"
# args: 1,
# only-under: ~/Documents
# call: $0 $@
```

| Header | Means |
| --- | --- |
| `name` | the menu item's title; the file name without its extension if left out |
| `description` | the menu item's tooltip |
| `apply-to` | an expression of the [flat view's language](#flat-view) that every selected item must pass; anything if left out |
| `extensions` | **deprecated**, still obeyed: every selected item must have one of these extensions. `apply-to: name = "*.txt", name = "*.png"` says the same |
| `args` | how many items: `1` exactly one (the default), `1,3` one to three, `2,` two or more, `0` none -- a script about the folder on screen, offered in File ▸ Scripts when nothing is selected and when right-clicking the empty space below the rows |
| `only-in` | folders the items must be directly in |
| `only-under` | folders the items must be in or below |
| `call` | **required**: the command line -- `$0` is the script, `$1`, `$2`… one item each, `$@` all of them |
| `source` | where it was published: `diptych` for the scripts that come with Diptych |
| `version` | a whole number from 1; Get Scripts offers a higher one of its own as an update |
| `signature` | reserved for signed scripts from GitHub; accepted and not yet checked |

**`apply-to` is a whole expression**, asked of each selected item on its own:
`file and name = "*.jpg"`, `image and located`, `size > 100MB`, `not link`,
`owner = "peter"`, `contains "TODO"`. The old `file, directory, link` still
reads the same, since a comma is OR. Because each item is asked alone, nothing
is walked: a folder is never `directory traversed`, and a file under `.git` is
told apart by its path -- `path != "*/.git/*"` -- not by skipping the folder.
As everywhere in the language, a link also counts as what it leads to, so
`file` takes a link to a file (`file and not link` does not), and an app or
other package is one item, a `file`, not a `directory`. Expressions saved in
the flat view cannot be used: a script is handed to other people, and has to
mean the same on their Mac. Tests that read the file, such as `contains` or a
picture's EXIF, are run when the menu opens, so keep them for small
selections.

Making an archive is the typical case -- the header above is one. Archives
need nothing else from Diptych: **Space** lists what is in one, and **Return**
opens it in Archive Utility, which unpacks it into a folder of the same name
beside it, ready to browse.

A script is offered only when **every** selected item qualifies: a selection of
three where one is the wrong kind is not two-thirds applicable.

**No shell is involved.** The `call` line is split into words *before* anything
is substituted, so each item is exactly one argument whatever its name holds --
`my notes (draft).txt` needs no quoting. `$*` is refused, since it is the thing
that breaks on a space. The script runs in your home folder, from a private copy
of what you approved, with the panes in `DIPTYCH_LEFT`, `DIPTYCH_RIGHT`,
`DIPTYCH_ACTIVE` and `DIPTYCH_OTHER`, whether both panes are on screen in
`DIPTYCH_SINGLE_PANE` (`1` when only the active one is, so `DIPTYCH_OTHER` is a
pane the person cannot see and should not be written to), and its own real path
in `DIPTYCH_SCRIPT`;
a script that wants a pane says so, with `cd "$DIPTYCH_ACTIVE"`. It runs in a
tab of the **Runs** window, like Run ▸, with Stop, Copy Output, the exit status
and the timing, and both panes are refreshed when it ends.

**A mistake in a header is reported** when Diptych starts -- an unknown setting
(`# extension:` for `# extensions:`), an `apply-to` that does not parse or
that nothing can pass, a bad `args`, a missing `call`, a `$3` in
a script never given three items -- with the file and line, rather than the
script quietly missing from the menu.

**What it will not run.** The danger is not a dishonest author but a script
that arrived by post, so Diptych refuses a file that:

- came from outside this Mac (it carries `com.apple.quarantine`);
- belongs to somebody else;
- can be written to by anyone, you included -- a download lands as
  `rw-r--r--`, so installing a script has to be a deliberate act, and an
  approved script cannot change afterwards;
- anybody else can read -- a script is a fair place to keep something private.

So a script is `r--------` (`400`): select it and press `⌥⌘P` to set that.
**Nothing lifts these rules**, developer mode included. You are asked before a
script runs for the first time and again whenever its contents change; the
approvals are kept, by a hash of the contents, in
`~/.diptych/scripts-approved.json`. Every rule is checked again at the moment
of running, and a script changed since it was read is refused rather than run.

**The folder is read once, at startup** -- a script that could change between
being agreed to and being run would make the agreement worth nothing.
**Developer mode** (Settings ▸ Behaviour, under the scripts setting) adds **File
▸ Read the Scripts Folder Again** for whoever is writing scripts. It relaxes
nothing else.

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

## Roadmap

Ideas, roughly in the order they would be useful, and the loose ends left
over. None of it is promised.

### Archives and disk images

- **An archive opened without unpacking it all.** Opened as a folder it is
  still unpacked whole first, now into a locked name-mirror tree with a
  manifest of the archive's metadata in each directory -- the groundwork for
  a listing that does not touch the bytes. A very large archive could then be
  listed at once from the manifest alone, each file taken out of the archive
  only when it is looked at or copied: the opaque indexed backing store in
  `object-browser-design.md`.

### Older versions

- **Time Machine and APFS snapshots.** Every backed-up version of a file,
  each one open to Quick Look, Compare with the current one, or Restore; a
  folder compared with itself as it was last week.
- **A Trash browser.** The Trash of every volume in one pane, with where each
  item came from and Put Back.

### What Finder does not tell

- **Code signature and notarization** in the Info window: who signed an app,
  whether Apple notarized it, its entitlements, why Gatekeeper would refuse
  it -- and the same for the agent through MCP.
- **Checksums.** SHA-256 and the others in Details; a file checked against a
  `.sha256` file, or against a hash copied from a download page.
- **Disk use as a treemap.** The directory sizes already measured, drawn as a
  treemap or sunburst to click into.

### The panes

- **Tabs inside a pane.** `⌘T` gives macOS window tabs, each a whole two-pane
  window. Tabs *inside* a pane -- what file managers usually mean -- would be a
  list of folders per `PaneModel` plus a tab strip.
- **Open With ▸ and Share ▸** in the right-click menu, as in Finder; Share
  brings AirDrop, Mail and Messages.
- **Spotlight as a flat view.** `mdfind`'s results in one list, filtered by
  the flat view's expression: a whole disk searched by content at once.

### Remote

- **An SFTP pane.** macOS cannot mount SFTP; Diptych could browse and copy
  over the user's own `ssh`, with its keys and `~/.ssh/config`.

### Smaller

- **Split and join** a large file, with a checksum of the whole.
- **Text encodings and line endings** converted in Text Edit.
- **PDF pages**: merged, split and turned, beside Make PDF -- or left to the
  agent, as workflows are.

### Loose ends

- **First click when Diptych is not frontmost** may select nothing -- macOS
  spends it bringing the app forward. Patching `acceptsFirstMouse` by
  re-classing SwiftUI's private table view crashed AppKit's derived-property
  system, so it was reverted; a local `.leftMouseDown` monitor is the safe
  route. `ClickRouter` already does this for a click into a window behind the
  Quick Look panel; whether it covers an inactive app is not yet checked.
- **Undo for a sync** in Compare Folders. Deleted and replaced files are in
  the Trash until then.
