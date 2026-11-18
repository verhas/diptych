# What Diptych keeps, and where

Everything Diptych writes for itself is in `~/.diptych`, apart from a few
caches and macOS preferences listed at the end. This page says what each file
and folder is, which version brought it, and -- for the ones that are gone --
which version replaced it and with what.

Versions are those released on GitHub. 1.13.0 is the last 1.x release; 1.13.1
was prepared but never released, and what it would have brought shipped in
2.0.0. "Since" is the first release that wrote the file; "until" is the last
one that did.

Two rules hold for all of it:

- **Diptych never needs you to touch these files.** Most of them can be edited
  by hand, and those that are meant to be say so below. The databases are
  not: edit them with Diptych, or with `sqlite3` while Diptych is not running.
- **An upgrade carries everything forward.** A file a newer version no longer
  uses is read once, brought into its replacement, and deleted -- from any
  1.x to any later version (`LegacyRecords`). A file that cannot be read is
  left where it is and tried again at the next start, never deleted.

## At a glance

| Name | What | Since | Until | Replaced by |
| --- | --- | --- | --- | --- |
| `~/.diptych` as a file | the window state | before 1.0.0 | before 1.0.0 | `state.json`, in the folder |
| `config.json` | every setting | 1.0.0 | -- | |
| `state.json` | windows and panes as left | 1.0.0 | 1.13.0 | `diptych.sqlite` (2.0.0) |
| `scripts/` | your scripts | 1.1.0 | -- | |
| `scripts-approved.json` | scripts you said yes to | 1.1.0 | 1.13.0 | `diptych.sqlite` (2.0.0) |
| `prompts/prompt1.tmpl` | what F1 sends an agent | 1.1.0 | -- | |
| `prompts/names.tmpl`, `prompts/names/` | how a name is asked for | 1.2.0 | -- | |
| `release-notes-version` | the release notes last shown | 1.3.2 | -- | |
| `.mcp.token` | the MCP server's token | 1.4.0 | -- | |
| `agentic/` | the agent terminal's folder | 1.5.0 | -- | |
| `provenance.sqlite` | who made a file, looked up | 1.5.0 | -- | |
| `runs/` | runs and their output | 1.6.0 | -- | |
| `run-history/` | arguments programs ran with | 1.6.0 | -- | |
| `exif/` | cameras, lenses, places | 1.8.0 | -- | |
| `filters/` | saved flat view expressions | 1.8.0 | -- | |
| `servers.json` | servers connected to | 1.9.0 | 1.13.0 | `diptych.sqlite` (2.0.0) |
| `sync/` | how synced folders last stood | 1.10.0 | -- | |
| `trash-origins.json` | where trashed files came from | 1.12.0 | 1.13.0 | `diptych.sqlite` (2.0.0) |
| `sftp_known_hosts` | SFTP servers' keys | 1.13.0 | -- | |
| `templates/` | the PDF report's look | 1.13.0 | -- | |
| `diptych.sqlite` | your records | 2.0.0 | -- | |
| `cache.sqlite` | what was worked out | 2.0.0 | -- | |
| `journal.sqlite` | the journal | 2.0.0 | -- | |
| `spotlight.sqlite` | what was given to Spotlight | 2.0.0 | -- | |
| `script-timings.json` | how long scripts take | never released | | `diptych.sqlite` |

A SQLite database comes with `-wal` and `-shm` files beside it while it is in
use: they are part of it. Copy all three, or none.

## The databases

### `diptych.sqlite` -- since 2.0.0

What Diptych remembers for you and could not work out again. Readable only by
you (0600). Never emptied by Diptych: if it is damaged it is renamed
`diptych.sqlite.damaged-<date>`, kept for you to look at, and a new one is
made. A newer version only ever adds tables or columns, so an older version
can still use a newer file. (`LocalDatabase.records`)

| Table | Holds | Was |
| --- | --- | --- |
| `window_state` | each window: its frame, which pane has the keyboard, one pane or two, sidebar, hidden files | `state.json` |
| `pane_state` | each pane of each window: folder, sort, view (list or icons, and how icons are arranged), flat view expression and draft | `state.json` |
| `pane_recent` | each pane's recent folders, in order | `state.json` |
| `server` | servers connected to: address (never a password), starred, connect at start, last used, last mount point, keep-alive, the checksum command it has | `servers.json` |
| `trash_origin` | each file Diptych moved to the Trash and where it was; forgotten once the file has left the Trash | `trash-origins.json` |
| `script_timing` | per script: runs, shortest, longest, total, and the same per file -- sums only, never which files | `script-timings.json` |
| `script_approval` | the fingerprint of each script's contents you said yes to | `scripts-approved.json` |

`state.json` was written as JSON meant to be edited by hand; the tables are
not. A server's keep-alive and checksum command were lost at every start of
1.x, which read `servers.json` without them; the import brings them in.

### `cache.sqlite` -- since 2.0.0

What Diptych works out and keeps only so as not to work it out again. Nothing
in it is yours: lost, damaged or from a version with different tables, it is
emptied and made again, and the work is redone. Readable only by you.
(`LocalDatabase.cache`)

| Table | Holds |
| --- | --- |
| `browser_source` | each opened archive and each SFTP server's cache: its folder, kind, where it came from |
| `browser_folder` | each folder of those listed, with its inode, so a folder deleted and made again reads as never listed |
| `browser_node` | each item of a listed folder: name, kind, size, permissions, owner, dates, link target, whether its bytes are here, for a server's file its checksum and whether it was changed here or there |
| `folder_size` | each folder Calculate Directory Sizes measured: its size, when, and whether the total was finished or still growing; purged after Settings ▸ Behaviour ▸ Folder Sizes (a week) |

Version 1 of the file had only the first three tables. 2.0.0 adds the fourth
to a version 1 file rather than emptying it.

The first three replace the `__DIPTYCH.json` files 1.12.0 and 1.13.0 wrote
into every folder of an opened archive or a server's cache -- see *Elsewhere*.

### `journal.sqlite` -- since 2.0.0

The journal: everything Diptych did, with the files it touched, kept 90 days
unless Settings ▸ Behaviour ▸ Journal says otherwise. Readable only by you.
Window ▸ Journal searches it; Delete Journal… empties it. (`Journal`)

### `spotlight.sqlite` -- since 2.0.0

Which files were given to Spotlight as records, and with what date and size,
so a file is indexed again only when it changes, and its record taken back
when it leaves a listing. Used only while *Add the files Diptych shows to
Spotlight* is on. (`SpotlightRecords`)

### `provenance.sqlite` -- since 1.5.0

The apps behind `com.apple.provenance` numbers, looked up in a database only
the administrator can read, so each is asked about once. (`Provenance`)

## Files and folders

### `config.json` -- since 1.0.0

Every setting, as JSON, written whenever a setting changes and read once, at
start. **Meant to be edited by hand**, with Diptych not running: a setting the
Settings window gets wrong can be put right here. A key it does not know is
ignored, and a missing one takes its default, so a file from an older or a
newer version works. Not moved into a database, for both reasons.
(`ConfigStore`)

### `state.json` -- 1.0.0 until 1.13.0

The windows and their panes as they were left: frames, folders, sort, view,
recent folders. Since 2.0.0 in `diptych.sqlite`, brought in at the first start
and deleted.

Before 1.0.0, development builds wrote the same thing as the file
`~/.diptych` itself. Every version since turns such a file into the folder,
with the state in it as `state.json`, which 2.0.0 then brings in.

### `scripts/` -- since 1.1.0

Your scripts, for the Scripts menu, and those File ▸ Get Scripts installs. A
script runs only when it is yours, readable and writable by nobody else, not
downloaded, and approved -- see the README's *Scripts*.

### `scripts-approved.json` -- 1.1.0 until 1.13.0

The scripts you said yes to, by a hash of their contents. Since 2.0.0 the
`script_approval` table. Losing it fails safe: you are asked again.

### `prompts/` -- since 1.1.0

- `prompt1.tmpl` (1.1.0) -- what F1 fills in and sends an agent. Written the
  first time it is needed; yours to edit.
- `names.tmpl` and `names/<folder>.tmpl` (1.2.0) -- what Apple Intelligence is
  told when it suggests a name, everywhere and for particular folders.

### `release-notes-version` -- since 1.3.2

The version whose release notes were last shown, so they are shown once per
update. Kept apart from `config.json` so that resetting settings does not show
them again. (`ReleaseNotesSeen`)

### `.mcp.token` -- since 1.4.0

The MCP server's bearer token, owner-read-only, kept out of `config.json`
because that file is meant to be read and edited. (`MCPTokenStore`)

### `agentic/` -- since 1.5.0

The agent terminal's folder, unless Settings choose another. Diptych writes
`AGENTS.md` and `CLAUDE.md` -- the agent's instructions, rewritten at each
start for as long as their first line is Diptych's; delete that line and they
are yours -- and `.mcp.json`, of which it changes only the `diptych` entry.
Anything else in it, such as `.claude/`, is the agent's own.

### `runs/` -- since 1.6.0

Each run of a script or program: `<id>.json` the record, `<id>.log` what it
printed. Readable only by you; kept a day unless Settings ▸ Behaviour says
otherwise. (`RunLog`)

### `run-history/` -- since 1.6.0

The argument lines each program was run with, one JSON file per program named
by a hash of its path. Meant to be edited: a program's own `limit`,
`unlimited` and `fixed`. (`RunHistory`)

### `exif/` -- since 1.8.0

`cameras.json`, `lenses.json` and `places.json`: the makes, models and places
the EXIF editor offers and names locations by. Written at the first start,
merged with each later version's lists; what you add or disable stays.
(`ExifDatabase`)

### `filters/` -- since 1.8.0

Flat view expressions saved under a name, one JSON file each, with every
earlier version of the expression. (`FlatFilterStore`)

### `servers.json` -- 1.9.0 until 1.13.0

Servers connected to. Since 2.0.0 the `server` table.

### `sync/` -- since 1.10.0

How two folders stood after their last sync in Compare Folders, one file per
pair, so that a sync both ways can tell a new file from a deleted one.
(`SyncBaseline`)

### `trash-origins.json` -- 1.12.0 until 1.13.0

Where the files Diptych trashed came from. Since 2.0.0 the `trash_origin`
table.

### `sftp_known_hosts` -- since 1.13.0

The SFTP servers' keys you accepted, in `known_hosts` form. Diptych reads
`~/.ssh/known_hosts` but never writes it; this is its own list.

### `templates/` -- since 1.13.0

`pdf-report/`: the HTML template and stylesheet Explain with an Agent writes
its reports with. Yours to edit.

### `script-timings.json` -- never in a release

How long each script takes. Written by 2.0.0 development builds only, and
moved into the `script_timing` table before 2.0.0 was released; brought in
like the others if it is there.

### Anything else

A file not listed here was not written by a released Diptych:
`windowsmenu-probe.log`, for one, was left by a development build, and can
be deleted. So can `diptych.sqlite.damaged-<date>` once you have no use for
it.

## Elsewhere

Not in `~/.diptych`, and none of it yours: all of it can be deleted while
Diptych is not running.

| Where | What | Since |
| --- | --- | --- |
| `~/Library/Caches/dev.verhas.Diptych/Opened Archives/` | archives opened as folders, unpacked; removed at quit | 1.12.0 |
| `~/Library/Caches/dev.verhas.Diptych/Opened Servers/` | each SFTP server's files fetched so far; kept between starts | 1.13.0 |
| `~/Library/Caches/dev.verhas.Diptych/Dragged Out/` | clean copies handed to drags and pastes out of archives; removed when a day old, and at the next start, except those still on the clipboard | 2.0.0 |
| `~/Library/Caches/dev.verhas.Diptych/Undo/` | files as they were before an EXIF edit, for Undo; one folder per running Diptych | 1.8.0 |
| `~/Library/Caches/Diptych/Visual/v1/` | how two PDFs or pictures were aligned and compared | 1.13.0 |
| `~/Library/Preferences/dev.verhas.Diptych.plist` | macOS's own window and panel state, and the last options of Optimize (1.11.0), Create Archive (1.11.0) and text recognition (1.8.0) | 1.0.0 |

**`__DIPTYCH.json`, 1.12.0 until 1.13.0.** What an opened archive or a
server's folder held -- permissions, owner, dates, what had been fetched --
was written as this file into every folder of the caches above. 2.0.0 keeps
it in `cache.sqlite` and does not read the old files: an opened archive is
unpacked afresh anyway, but a server's cache from 1.13 should be deleted
before upgrading (the 2.0.0 release notes say how).

**On your own files**, Diptych writes nothing of its own but:

- `<file>.diptychsplit.json` (1.12.0), the manifest Split File writes beside
  the parts, which Join Parts reads;
- the extended attribute `dev.verhas.diptych.run-history` (1.6.0) on a
  program run with arguments, pointing at its file in `run-history/`;
- `.git/info/exclude` lines and `diptych-kept-<date>` branches in a Git
  repository, when version tracking keeps a copy of your version
  (1.1.0; see `git-integration.md`).

**The Keychain** holds nothing of Diptych's own. An SSH key's passphrase goes
there through `ssh-agent`, as `ssh`'s `UseKeychain` puts it (1.13.0); a
server's password is kept in memory only, until eject or quit.
