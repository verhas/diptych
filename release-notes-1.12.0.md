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

## Fixes

- A zip made of **one file** held its folder too -- `Downloads/notes.txt`
  rather than `notes.txt`. It holds the file alone now, as Finder's Compress
  makes it; a folder is still kept whole.

## Upgrading

Nothing to do.

---

*1353 tests.*
