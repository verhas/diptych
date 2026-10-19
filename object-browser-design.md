# Object browser architecture

*Status: design + first implementation under way (the manifest format and
`ArchiveSource`). The pane is not yet pointed at it; the live archive-as-folder
feature still uses the older direct-extraction path until the wiring lands.*

## Why

Today a Diptych pane assumes it shows a real directory it can `stat` and
enumerate. Opening an archive as a folder stretched that: the files are
unpacked into a cache and the pane lists the cache, so it shows the cache
copy's permissions and dates (not the archive's), and the files are writable,
which lures someone into editing a copy that is thrown away.

The fix is to stop inferring a listing from a real directory and instead take
it from a **manifest** the source produces: display metadata (names,
permissions, owner, dates) comes from the manifest, and the actual bytes for
Open / Quick Look / copy-out live in an opaque backing store that the display
never reads metadata from. Once display is decoupled from the backing files,
read-only protection becomes free, and — the larger point — the same mechanism
can list things that are not files at all.

## The one rule

**Object browser inside, two-pane file manager outside.** The architecture is
a general object browser; version 1 ships exactly one object type, the local
file system, plus manifest-backed file sources (archives now; SFTP and disk
images later). A simple user never sees the word "manifest" or "source": an
archive looks like a folder, the columns are the usual file columns, and the
File menu is the usual verbs. The generalization lives in **how a listing and
its metadata are produced**, never in what the ordinary user is shown. Version
2.0.0 may add non-file sources (processes, login items, `defaults` domains…);
they appear only where someone goes looking for them, and the default
experience is unchanged.

Everything below is chosen so that v2 needs new *sources*, not a new *format*
and not a new *pane*.

## Layers

```
          ┌──────────────────────────────────────────┐
  UI      │ PaneModel · FileItem · columns · File menu │   unchanged for the user
          └───────────────────────┬────────────────────┘
                                  │ asks for a listing / a local file
          ┌───────────────────────┴────────────────────┐
  Source  │ BrowserSource protocol                      │   the seam
          │   LocalFileSystemSource   (the identity)    │
          │   ArchiveSource           (v1)              │
          │   SFTPSource, DiskImageSource   (later)     │
          │   ProcessSource, DefaultsSource (v2)        │
          └───────────────────────┬────────────────────┘
                                  │ serialized as
          ┌───────────────────────┴────────────────────┐
  Format  │ BrowserManifest (JSON): nodes with typed    │   general from day one
          │ attributes, capabilities, columns, backing  │
          └─────────────────────────────────────────────┘
```

- **Format** is general immediately, so it never has to change to admit a new
  source kind.
- **Source** is where each kind lives. v1 implements the file-shaped ones.
- **UI** keeps the file-manager vocabulary. It maps a manifest `Node` to a
  `FileItem` for file sources; a future object source would supply its own
  columns, but that is additive.

## The manifest format

One manifest describes **one directory's listing** (not the whole tree), so a
lazy source can answer a directory at a time (the SFTP model) and a huge
archive need not be described all at once.

```jsonc
{
  "schema": 1,
  "source": "archive",                 // "sftp", "process"… later
  "origin": { "path": "...", "sha256": "...", "holder": "..." },
  "capabilities": { "writable": false },
  "columns": null,                     // null = the standard file columns
  "nodes": [
    {
      "id": "2024/invoice.pdf",        // stable within the source
      "kind": "file",                  // directory | symlink | other | (v2) process, setting…
      "name": "invoice.pdf",
      "attributes": {                  // typed; file sources use well-known keys
        "size":  { "t": "size", "v": 20480 },
        "mode":  { "t": "mode", "v": 420 },
        "uid":   { "t": "user", "v": 501 },
        "gid":   { "t": "user", "v": 20 },
        "mtime": { "t": "date", "v": 1699900000.0 }
      },
      "linkTarget": null,              // for a symlink, shown, never followed off-source
      "backing": { "t": "file", "v": "store/7/invoice.pdf" }   // or "report", or absent (lazy)
    }
  ]
}
```

Design points that keep it future-proof:

- **Typed attributes, not fixed columns.** File sources use the well-known
  keys above; a process source would use `pid`, `cpu`, `command`. The value is
  tagged (`t`) so the UI knows how to render and sort it without knowing the
  source. v1 maps the file keys onto `FileItem`; nothing else needs the general
  path yet.
- **`id` is not a path.** For files it is the path relative to the source root;
  for a process it would be a pid, for a `defaults` item a domain+key. The UI
  treats it as opaque.
- **`backing` is how you get bytes**, separate from how you display. A file
  points into the opaque store; generated content (a process report, a folder
  listing) is `report`; a lazy source leaves it absent until materialized. So
  "open this" never means "re-read its display metadata."
- **`source` is the listing's type, and the code dispatches on it.** Diptych
  is not a pluggable host of uniform items whose actions are declared as data
  — a file, an image, a directory and an archive already behave differently,
  and a process list would offer a different Kill for a user process than for
  a system one. So menus and actions are written in code, keyed by this type
  and reading each node's attributes; they are **not** listed in the manifest.
- **`capabilities`** carries `writable` (and may grow other true/false
  capabilities). It does not carry an action list.
- **`columns`** is `null` for file sources (use the standard ones). A future
  object source supplies its own; the pane renders what it is told.

## The backing store

> **Version 1 uses a locked name-mirror with a manifest overlay, not the
> indexed store below.** The archive is unpacked into a real directory tree
> (so copy-out of a whole folder, Quick Look of a folder, and every file
> operation stay correct with no new code), the tree is locked read-only (so
> nothing can write over the copy), and each directory carries a manifest the
> loader overlays for the permissions, owner and group the locked copy cannot
> show. The indexed store described here needs copy-out to become
> extract-a-subset first, or copying a folder out would produce an incomplete
> tree; it is deferred until that is built. The rest of this section is the
> target design.

Extracted bytes live in a **flat, indexed store**, never a name-mirror of the
archive:

```
<holder>/                       (one opened archive, cacheRoot/<UUID>)
  tree/                         skeleton: directories only, each with a manifest
    __DIPTYCH.json
    2024/__DIPTYCH.json
  store/                        opaque indexed backing files
    1/report.md   7/invoice.pdf   ...
```

- **Opaque index + real leaf name** (`store/7/invoice.pdf`). The index keeps
  siblings unique even when the archive holds `A.txt` and `a.txt` (which cannot
  coexist on case-insensitive APFS) or hostile names; the real leaf name
  preserves the extension so Quick Look and Open pick the right renderer. And
  because the backing path is visibly a cache path, an external app's Save
  dialog makes it obvious you are **not** writing into the archive.
- **`tree/` holds only directories**, so the pane can navigate into them as
  real folders. Files and symlinks exist only in the manifests; their bytes are
  in `store/`. Symlinks are shown with their target as data and are never
  created as live links that could escape the cache (zip-slip is contained the
  same way: the displayed name is text, the backing path is sanitized).
- **The manifest file name** is `__DIPTYCH.json`, hidden from the listing. If a
  real subdirectory in that folder is itself named `__DIPTYCH.json`, the
  manifest escalates to `__1DIPTYCH.json`, then `__2DIPTYCH.json`; the reader
  uses the `__(n)DIPTYCH.json` with the largest `n` and hides exactly that one.
- **Read-only.** The `tree/` directories and `store/` files are `0500`/`0400`,
  and `capabilities.writable` is false, so nothing in the pane — rename, move,
  trash, drop, **or editing a permission bit, owner, tag or any in-place
  field** — is offered. Display metadata comes from the manifest regardless of
  what the backing files' real modes are, so the honest archive permissions
  show even though the bytes on disk are locked.
- Everything under `<holder>` is removed when Diptych quits, and leftovers from
  a crash at the next launch.

## How the UI stays a file manager

- A pane whose directory is inside a source builds its `FileItem`s from the
  manifest, not from `stat`, and routes Open / Quick Look / copy-out to the
  node's backing file. The displayed path reads inside the archive
  (`~/Downloads/photos.zip/2024`), and Up from the top lands beside the
  archive. (This wiring is the next increment; the format and `ArchiveSource`
  come first.)
- Copy/drag **out** of a source is "materialize this subset" — it applies the
  archive's recorded owner/mode/quarantine, the same logic Extract already
  has, so copy-out and Extract become one path.
- The flat-view query language already filters by fields; pointed at a
  manifest it filters the same way, and later at arbitrary attributes
  (`cpu > 50`) for free.
- The MCP agent reads what a pane shows, so it sees a source's listing through
  the same mechanism — useful now for archives, and later for "what starts at
  login?".

## Migration plan

1. **Format + `ArchiveSource`** — the manifest types and a source that unpacks
   an archive, writes per-directory manifests and locks it. *(done)*
2. **Loader overlay** — the directory loader lists the locked tree and overlays
   each manifest for the archive's permissions, owner and group, hiding the
   manifest file. `ArchiveBrowsing.open` builds an `ArchiveSource`. *(done)*
3. **Indexed store + copy-out as extract-a-subset** — move bytes into the
   opaque store, and intercept copy/drag out of a source to materialize the
   selected subtree with the archive's metadata. Together, so folder copy-out
   stays correct.
4. **`LocalFileSystemSource`** — express the ordinary file system as the
   identity source, so there is one code path. Behaviour is unchanged; this is
   a refactor, done when it buys clarity, not before.
5. **More file sources** — SFTP (writable: save = upload), disk images.
6. **v2 object sources** — processes, login items, `defaults`, each with its
   own columns and actions, reachable only where someone looks for them.

## What v2 needs that v1 already provides

- Arbitrary typed attributes and source-declared columns — in the format now.
- Backing as `report` for generated detail views — Diptych already generates
  HTML reports (folders, plists, `.DS_Store`), so a process report is the same
  shape.
- Non-file verbs (kill, enable/disable) — written in code keyed by the
  listing's type, reading each node's attributes, and surfaced as a context
  menu; not declared as data in the manifest.
- Admin elevation for privileged actions — `Privileged.run` already exists.

## What v2 still needs (deliberately deferred)

- A pane that lists a source with **no real `tree/` directory** (fully virtual
  navigation) — v1 uses real skeleton dirs to reuse today's navigation.
- A **live-refresh** model for sources whose data changes under you (processes
  come and go); FSEvents does not apply, so such a source polls or subscribes.
- Provider-declared **columns in the pane UI** (v1 uses the fixed file columns).
- An **action/write UI** beyond the File menu.

None of these require a format change — only new source implementations and
additive UI.
