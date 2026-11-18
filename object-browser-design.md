# Object browser architecture

*Status, as of 2.0.0: two sources are built and shipped. Opened archives came
in 1.12.0, and SFTP servers in 1.13.0. Since 2.0.0 their listings are
kept in `~/.diptych/cache.sqlite`; the `__DIPTYCH.json` file once written
into every folder is gone. Non-file sources (processes, login items,
`defaults`) are still only a design. Section "Not built" lists what the
original plan has that the code does not.*

## Why

A Diptych pane assumes it shows a real directory it can `stat` and enumerate.
Opening an archive as a folder stretched that: the files are unpacked into a
cache and the pane lists the cache. On its own, that shows the cache copy's
permissions and dates, not the archive's. The files would also be writable,
which lures someone into editing a copy that is thrown away.

The fix is to stop inferring a listing from a real directory and take it from
a **manifest** that the source produces. Display metadata (names,
permissions, owner, dates, sizes) comes from the manifest. The bytes for
Open, Quick Look and copy-out live in a backing store whose own metadata the
display never reads. Once display is decoupled from the backing files,
read-only protection comes free. The larger point is that the same mechanism
can list things that are not files at all.

## The one rule

**Object browser inside, two-pane file manager outside.** The architecture is
a general object browser, but what ships is the local file system plus two
manifest-backed file sources: archives and SFTP servers. A user never sees
the word "manifest" or "source". An archive looks like a folder, a server
looks like a volume, the columns are the usual file columns, and the File
menu has the usual verbs. The generalisation lives in **how a listing and its
metadata are produced**, never in what an ordinary user is shown. Non-file
sources, if they come, appear only where someone goes looking for them, and
the default experience stays the same.

Everything below is chosen so that a new kind of thing needs a new *source*,
not a new *format* or a new *pane*.

## Layers

```
          ┌────────────────────────────────────────────────┐
  UI      │ PaneModel · FileItem · columns · File menu     │  unchanged for the user
          └───────────────────────┬────────────────────────┘
                                  │ lists a real folder, overlaid
          ┌───────────────────────┴────────────────────────┐
  Source  │ ArchiveSource   (BrowserSource)                │  the seam
          │ SFTPMirror      (an actor of its own)          │
          │ the local file system: the identity, implicit  │
          └───────────────────────┬────────────────────────┘
                                  │ writes its listings to
          ┌───────────────────────┴────────────────────────┐
  Store   │ BrowserManifestStore over LocalDatabase.cache  │  ~/.diptych/cache.sqlite
          │ sources · folders · nodes, in typed columns    │
          └───────────────────────┬────────────────────────┘
                                  │ read back as
          ┌───────────────────────┴────────────────────────┐
  Format  │ BrowserManifest: nodes with typed attributes,  │  in memory; general
          │ capabilities, columns, backing                 │
          └────────────────────────────────────────────────┘
```

- **Format.** `BrowserManifest` is the in-memory shape of one folder's
  listing. It is still `Codable` and still general (typed attributes, opaque
  ids, optional columns), but it is no longer written to a file.
- **Store.** `BrowserManifestStore` keeps every listing in the cache
  database, and posts `BrowserManifestStore.changed` when one changes, which
  is how a pane learns that it should list again.
- **Source.** Each kind lives here. `BrowserSource` is the protocol;
  `ArchiveSource` adopts it. `SFTPMirror` produces the same listings but is an
  actor with its own interface: it lists lazily, fetches on demand, and
  writes back, none of which the protocol describes.
- **UI.** It lists the real backing folder and has `DirectoryLoader.browserOverlay`
  lay the stored listing over it, so a manifest node becomes a `FileItem`
  with the source's mode, owner, group, dates and size.

## The format

One listing describes **one directory**, not the whole tree. A lazy source
can then answer one directory at a time (the SFTP model), and a huge archive
need not be described all at once.

```swift
struct BrowserManifest {
    var source: String                 // "archive", "sftp"; what code dispatches on
    var origin: [String: String]       // the archive's path and SHA-256, the holder
    var capabilities: Capabilities     // writable, and room for more true/false ones
    var columns: [Column]?             // nil: the standard file columns
    var nodes: [Node]
}

struct Node {
    var id: String                     // stable within the source; not necessarily a path
    var kind: Kind                     // directory, file, symlink, other
    var name: String
    var attributes: [String: Value]    // typed: size, mode, user, date, text, number, flag
    var linkTarget: String?            // shown as text, never followed off the source
    var backing: Backing               // .file(path), .report, .none (not fetched yet)
}
```

Design points that keep it general:

- **Typed attributes, not fixed columns.** File sources use well-known keys
  (`size`, `mode`, `uid`, `gid`, `owner`, `group`, `mtime`, `btime`, and for
  servers `sha256`, `localMtime`, `serverChanged`). A process source would use
  `pid`, `cpu`, `command`. Each value is tagged, so the UI can render and sort
  it without knowing the source.
- **`id` is not a path.** For files it is the path relative to the source
  root. For a process it would be a pid; for a `defaults` item, a domain and
  a key. The UI treats it as opaque.
- **`backing` is how you get bytes**, separate from how you display them. A
  server file that has not been fetched is `.none`: its listing is complete,
  and its bytes are an empty placeholder until `materialize` fetches them.
- **`source` is the listing's type, and code dispatches on it.** Diptych is
  not a pluggable host of uniform items whose actions are declared as data. A
  file, an image, a directory and an archive already behave differently, and
  a process list would offer a different Kill for a user process than for a
  system one. So menus and actions are written in code, keyed by this type
  and reading each node's attributes; they are **not** listed in the manifest.
- **`capabilities`** carries `writable`, and may grow other true/false
  capabilities. It does not carry a list of actions.
- **`columns`** is nil for both file sources. The one source-specific column
  that exists, **Cached** for servers, is an ordinary pane column shown only
  in server listings, not a column the source declares.

## The store

The format was first serialised as a `__DIPTYCH.json` file in every folder of
the backing tree, hidden from listings. That went wrong in ways that all came
from the file living *beside* the data:

- **It travelled.** A folder dragged out of an archive took Diptych's
  manifests with it into Finder. Inside a copied `.app` bundle, a file the
  signature did not cover made the signature fail.
- **It needed telling apart** from an archive's own file of the same name.
  That was handled by escalating to `__1DIPTYCH.json`, `__2DIPTYCH.json` and so
  on, and every listing, path completion, upload and duplicate search had to
  filter it out.
- **It went stale silently.** A folder deleted and made again under the same
  name kept no listing, or the wrong one.

Since 2.0.0 the listings live in `~/.diptych/cache.sqlite`
(`LocalDatabase.cache`), in three tables:

| Table | One row per | Holds |
| --- | --- | --- |
| `browser_source` | opened archive or server shadow | kind, root (unique), holder, origin path and SHA-256, writable, when opened |
| `browser_folder` | directory that has been listed | its path relative to the root, **its inode**, when listed |
| `browser_node` | child of a listed folder | name, position, id, kind, and each well-known attribute in a typed column |

- **A folder's row is good only for the directory it was written for.** Its
  inode is kept with it. A directory deleted and made again under the same
  name, by anything, reads as never listed. For a server, a folder with no
  row means "not listed yet", and it is fetched when it is opened.
- **Deleting cascades**, so forgetting a source or a folder takes everything
  under it.
- **An unchanged listing is not written again**, and a changed one posts
  `changed` on the main queue with the folder's canonical path. A pane that
  shows that folder lists it again.
- **It is a cache.** Nothing in it is the person's own. A database that is
  lost, damaged, or from an older schema is emptied and made again, and the
  work is redone. WAL mode; one connection, used under a lock by whichever
  thread asks.
- **Lock order:** the store's list of roots is never locked while the
  database is. A test run uses a database of its own, never the person's.

The same database also keeps measured folder sizes (`folder_size`), which
is why it went to version 2: a version 1 file is kept and given the new
table, not emptied. What is the person's own -- servers, approvals, trash
origins, script timings -- is in a second file, `diptych.sqlite`, which is
never emptied (`LocalDatabase.records`).

## The backing store

Planned: a **flat, indexed store**. Directories only in a skeleton `tree/`,
and every file as `store/<n>/<leaf name>`, so that `A.txt` and `a.txt` could
coexist on a case-insensitive disk and hostile names would be harmless.

Built: a **locked name-mirror**. The indexed store needed copy-out to become
"extract a subset" first; otherwise copying a folder out would give an
incomplete tree. The name-mirror made every file operation correct with no
new code, and it has held up, so the indexed store is still not built.

**An opened archive** is unpacked once, as the user, into
`~/Library/Caches/<bundle id>/Opened Archives/<UUID>/<archive name>`. Zip (including `.jar`,
`.war`, `.ear`, `.ipa`), tar in its compressed forms, Apple Archive, and
encrypted Apple Archive (with a password) are supported.

- The tree is locked read-only, and the folder counts as a read-only volume.
  So nothing in the pane (rename, move, trash, drop, or changing a permission
  bit, owner, tag or any other field) is offered, and no other app can
  quietly write over the copy either.
- The path bar shows it where the archive is (`~/Downloads/photos.zip/2024`),
  and Up from its top lands beside the archive, with the archive selected.
- **It is watched.** An archive that is deleted or changed while it is open
  retires its unpacked copy. Panes inside it step out to where the archive
  was, and Back and the recent folders skip the stale copy
  (`ArchiveBrowsing.isCurrent`, `retireStale`).
- Opened again unchanged, it is shown at once. Everything goes at quit, and
  anything a crash left behind goes at the next start.

**A server's shadow** is one per server, rooted at the server's `/`, under
`~/Library/Caches/<bundle id>/Opened Servers/<user@host>`. Each folder that
has been listed is a real folder. Each file is an empty placeholder until it
is fetched, and the stored listing says which is which. Unlike an archive,
the shadow is **writable**, and it is kept between launches, so fetched files
need not be fetched again.

## How the UI stays a file manager

- **Listing.** `DirectoryLoader` lists the real backing folder, then
  `browserOverlay` lays the stored listing over it if the folder belongs to a
  registered source. Ordinary folders pay only for a look at the registered
  roots.
- **Paths.** An archive item shows as a path inside the archive; a server
  item as an `sftp://user@host/path` address. That is what the path bar, Copy
  Path, drags, the MCP tools and scripts are given. The mapping is made where
  a shown address and a real path meet (`ArchiveBrowsing`, `RemoteBrowsing`),
  so the pane itself needs no change for either.
- **Copying out of an archive** gives the copy the modes the manifest records,
  item by item, and the archive's quarantine, as Extract does
  (`unlockCopy`). The owner stays the user's. A drop always copies, so a
  copied app keeps a valid signature.
- **Dragging out to another app** hands over a clean copy, not the locked
  cache. Finder, given the cache's own files, copied their lock, and a folder
  of the copy could then not even be deleted. `handOut` makes an APFS clone
  beside the unpacked archives, so a folder of any size costs next to nothing,
  and unlocks it. The same drag read twice within a minute gets the same copy.
  Dropped back into Diptych, the copy maps back to the archive item
  (`original(of:)`), but only while that item still exists.
- **Copy and paste** promises the same copy. ⌘C puts a lazily provided file
  URL on the pasteboard, plus Diptych's own record of the item. Another app's
  paste makes the clone at that moment; Diptych's own paste copies from the
  archive. At quit, copies still promised on the clipboard are made before
  the unpacked archives go. Handed-out copies are removed when they are a day
  old and at the next start, except the ones the clipboard holds.
- **Servers write back.** Copy, move, rename, delete, new folder, mode, owner
  (through `sudo` if asked) and times are carried out on the server. A file
  edited in place is sent back on save, but only while the server still has
  the version that was fetched; otherwise the person chooses. A file the
  server lists as changed at the same size is compared by a checksum the
  server works out, not fetched.
- **The flat view, Find Duplicates, Compare, Quick Look and the MCP tools**
  work inside both sources because they work on the backing folders.

## What is built, against the original plan

1. **Format and `ArchiveSource`.** *Built.*
2. **Loader overlay.** *Built.*
3. **Indexed store, and copy-out as extract-a-subset.** *Not built.*
   Copy-out instead copies from the name-mirror and applies the archive's
   metadata, and drags and pastes get clones. Nothing has needed the indexed
   store yet.
4. **`LocalFileSystemSource`**, the identity source expressed through the
   protocol. *Not built.* It is a refactor, worth doing only when it buys
   clarity.
5. **More file sources.** *SFTP is built*, writable, with conflict checks
   on save. **Disk images are not a source.** They are mounted by macOS
   (`hdiutil`) and browsed as the volumes they are, which already shows real
   metadata. Their Quick Look preview reads the image without mounting it.
   **SMB, AFP and NFS servers** go through macOS's Connect to Server and are
   ordinary volumes too.
6. **Non-file sources.** *Not built.*
7. **The manifest moves into a database.** *Built, 2.0.0.* This step was not
   in the original plan.

## Not built

- **A pane that lists a source with no real backing directory** (fully
  virtual navigation). Both sources keep real folders so that today's
  navigation can be reused.
- **A live-refresh model for sources whose data changes underneath.**
  Processes come and go, and FSEvents does not apply, so such a source would
  have to poll or subscribe. For the two sources that exist, archives are
  watched for change, and servers are listed again when a folder is opened or
  refreshed.
- **Columns declared by the source**, shown in the pane.
- **An action UI beyond the File menu**, keyed by the listing's type.
- **Moving `SFTPMirror` onto `BrowserSource`.** The protocol is synchronous,
  and the mirror's work (listing, fetching, sending) is not. When a third
  source arrives, the protocol should grow `async` rather than gain an
  exception.
- **Bringing 1.13's listings into the database.** Server shadows made by 1.13
  still contain `__DIPTYCH.json` files. 2.0.0 neither reads nor removes them,
  so they show in those folders, and the first listing of each folder empties
  the files fetched before as though it had never seen them. A file edited and
  not yet sent would lose the edit. This needs a one-time import (or
  removal) at launch before 2.0.0 is released.

None of these needs a format change; only new source implementations,
additive UI, and the one migration.
