# Diptych 1.12.0

**Return on an archive opens it as a folder**: a zip, tar or Apple Archive is
shown read-only in the pane, and a disk image is mounted with its volume
shown. **Create Archive** can encrypt zips, Apple Archives and disk images
under a password, and makes **disk images** and **ISO** images too.

---

## An archive opened as a folder

- **Return** on a zip, tar, `.aar` or `.aea` -- or **Archive ▸ Open as
  Folder** -- shows what is in it in the pane. It is unpacked once into
  Diptych's caches, with a bar and Stop, and shown at once when opened again
  unchanged.
- Quick Look, Compare, copying and dragging out, the flat view and Find
  Duplicates all work inside it. It is **read-only**: nothing can be renamed,
  moved, trashed or dropped there, by you or by the agent.
- The path bar names it inside the archive -- `~/Downloads/photos.zip/2024`
  -- and Up from its top lands next to the archive, with it selected.
- Everything unpacked goes when Diptych quits.

## Disk images

- **Return** on a `.dmg`, `.iso`, `.cdr` or `.sparseimage` mounts it, as
  Finder does, and the pane goes to its volume; it is ejected from the sidebar.
  An encrypted one asks for its password.
- **Create Archive ▸ Disk Image** makes a `.dmg` of the selection: compressed
  with LZFSE, zlib or LZMA, read-only or read/write, APFS or Mac OS Extended,
  encrypted with AES-128 or AES-256 if you like. The items keep their
  attributes, tags and ACLs; the bar follows the copying and then hdiutil's
  own percent.
- **Create Archive ▸ ISO** makes an `.iso` -- ISO 9660, Joliet and UDF -- for
  a virtual machine, a disc, or a computer that is not a Mac.
- **A disk image can be a sidebar favourite.** Drag a `.dmg`, `.iso`, `.cdr`
  or `.sparseimage` onto the sidebar; clicking it later mounts it (asking an
  encrypted one's password) and goes to its volume.
- Settings ▸ Behaviour turns Return's way of opening them off; Open as Folder
  and Mount in Pane work either way.

## Passwords

- **A zip under a password**: AES-256, strong, opened by 7-Zip, Keka, The
  Unarchiver and Windows 11; or **ZipCrypto**, which everything opens,
  Archive Utility included -- and which free tools break in minutes, as the
  window says.
- **An Apple Encrypted Archive** (`.aea`), with a password of at least 20
  characters, opened by Archive Utility on macOS 13 and later.
- The password is typed twice, handed to the tool in a file only you can
  read and removed straight after -- never on a command line -- and never
  kept.
- **Extract** and **Open as Folder** ask for an encrypted archive's password,
  and again while it is wrong. A zip's password is checked by Diptych at
  once, rather than by tar's ten thousand tries.

## Recovering a ZIP password

For a zip that is **your own** -- one sent with a mistyped password, or an old
one whose password you have lost. **Archive ▸ Recover ZIP Password…**, the
right-click menu, and a **Recover Password…** button that appears on the
password prompt once a typed password is refused. The prompt also reminds you,
when a password is wrong, that there is no limit on tries and nothing locks you
out -- it is not signing in to a service. It tries passwords until one opens
the zip:

- **From a password you remember.** Type it as you recall it, wrong letters
  and all; candidates radiate outward by a *keyboard* edit distance -- the
  guess first, then a neighbouring key, a wrong case, two keys swapped, one
  doubled or dropped -- nearest first. A slip of a key or two is found fast.
- **Brute force.** Every string up to a length you set over an alphabet you
  pick. The search space and the time it would take on this Mac are shown
  first, and turn orange when the honest answer is "not in your lifetime".
- Found, the password is shown with **Copy**; the search runs on every core,
  with **Stop**. A ZipCrypto hit is confirmed by truly decrypting, so a
  one-in-256 false positive is never reported.
- The window says plainly that this is lawful on your own archives and may be
  a crime on someone else's, and points at the GPU tools -- hashcat, John the
  Ripper -- that do it in earnest past a short password.

## Previous versions of a file

- **File ▸ Previous Versions…**, or the right-click menu on a single file,
  shows that file's earlier selves from this Mac's **APFS snapshots** -- the
  hourly local snapshots macOS keeps on its own, and, with the backup disk
  attached, **Time Machine**'s longer history. Newest first, each with its
  date, source and size; a run of snapshots in which the file never changed is
  shown as the one moment it last did, so an unchanging file is not listed a
  hundred times.
- **Compare** -- or **⌘D** -- opens a version against the file as it is now, in
  the ordinary comparison window; the version is read-only, so looking never
  changes it. The list stays open behind it -- look, decide, try another, until
  one is right.
- **Restore** copies a version's contents back over the file in place. It is
  not a whole-volume rollback: the file keeps its name, permissions and
  attributes, only its contents change, and it is a single **Undo** step. It
  asks first.
- No password is ever asked and nothing is mounted by Diptych: it reads the
  snapshots the system already exposes, with Full Disk Access. A version the
  system has not exposed is shown as unavailable rather than forced open.

## Checksums

- A new **Checksum** menu. **Create ▸** MD5, SHA-1, SHA-256 or SHA-512 writes
  the sum into a file beside each selected one -- `photo.jpg.sha256` -- in the
  layout `md5` and `shasum` read. A checksum file that already holds the right
  sum is left alone; one that holds a stale sum is named and asked about before
  it is overwritten. On read-only media Diptych offers to make the files in the
  other pane instead.
- **Check** verifies the selection. With one file and a checksum on the
  clipboard -- a bare hash or a whole `hash  name` line -- it says which kind
  matched; with several files, or nothing copied, it checks each one against the
  checksum files beside it and reports every one as matching or not. It is also
  on the right-click menu.

## Choosing the right-click menu

- With so many file tools now on the right-click menu, a new **Menus** tab in
  Settings switches individual entries off to keep it short -- Checksum,
  Split/Join, Disk Usage, Previous Versions, the Image and Video tools and the
  rest. Everything is on by default, and the core (Open, Copy, Paste, New,
  Rename, Move to Trash) is never in the list.
- **Presets** set a group at once: Developer, Content Creator, Minimal, and
  Everything.

## Disk Usage

- **File ▸ Disk Usage…** (also on a folder's right-click menu) opens a window
  showing what fills a folder, drawn three ways from one scan and switched by a
  radio control: a **treemap** sized by bytes, a **heat map** coloured from cool
  to hot by size, and **Files** -- GrandPerspective-style rectangles, one per
  file, coloured by kind. Hover any rectangle for its path and size; click a
  folder in the treemap to go into it.

## The Trash

- Each volume in the sidebar has a small **trash** button on the left -- the
  opposite side from Eject, so a stray click never ejects the disk -- that opens
  that volume's Trash in the active pane (`~/.Trash`, or `.Trashes/<uid>` on
  another volume). Also on the volume's right-click menu.
- A Trash listing gains an **Original Location** column showing where each file
  was before it was trashed, on by default and shown only there. The long path
  shows in full on hover. It can be switched and repositioned from the pane's
  header menu while that pane shows a Trash (or in Settings ▸ Columns), and has
  an effect only on Trash listings. macOS keeps Finder's put-back privately, so
  this is filled from Diptych's own record of what it trashed -- a dash for
  anything trashed by Finder or another app.
- A trashed file's right-click menu offers **Restore to Original Location** and
  **Compare with the Original** (against whatever is at its old place now), for
  files Diptych trashed.

## More in the Info window

- **Signature**: a file's code signature and what Gatekeeper makes of it --
  signed or not, whether it verifies, the identifier, team and certificate
  chain, notarization and whether a ticket is stapled -- gathered from
  `codesign`, `spctl` and `stapler`, with the tools' own output under a
  disclosure.
- **Open Using**: every app that can open the file, the default marked; open it
  in one, or set the default for its kind.
- **Share**: the system share sheet (Mail, Messages, AirDrop, Notes, …) for the
  file.

## Splitting and joining a file

- **File ▸ Split File…** (also on the right-click menu) cuts a file into
  numbered parts -- `big.zip.001`, `big.zip.002`, … -- each no bigger than a
  size you pick, with the usual sizes (Email, CD, DVD, FAT32) ready to click.
- **Join Parts** reads a first part (`…​.001`) and the parts after it and writes
  the file back, byte for byte, stepping past a name already taken rather than
  overwriting it. Both are a single Undo step.

## Fixes

- **Going up out of an opened archive** from a subfolder could overshoot into
  Diptych's caches folder instead of leaving the archive. Up now always lands
  beside the archive, with it selected, however deep inside you were.
- A zip made of **one file** held its folder too -- `Downloads/notes.txt`
  rather than `notes.txt`. It holds the file alone now, as Finder's Compress
  makes it; a folder is still kept whole.

## Upgrading

Nothing to do.

---

*1434 tests.*
