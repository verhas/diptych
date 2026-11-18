# Diptych 2.0.0

**Space shows what is inside a file**, for the files Quick Look shows only as
a name and a size: Java classes, archives and key stores, certificates and
SSH keys, programs and app bundles, installer packages, disk images, e-mail,
crash reports, provisioning profiles, web locations, `.properties` files,
SQLite databases, and folders in a Git repository. **Source code is
coloured**, in Quick Look and in Text Edit, for over sixty languages. A
SQLite database opens in a **Database window** of its own. Panes show **icons**
as well as the list, where Finder placed them. A **journal** remembers what
Diptych did, for months. **Siri, Shortcuts and Spotlight** can use Diptych
the way an agent does. What is dragged or copied out of an opened archive
arrives as a **clean copy**. **Folder sizes are kept**, and shown again later,
fading as they age. **Apple Intelligence explains comparisons**, with the
model on this Mac, and **New from Clipboard** saves in the format the folder
already uses.

---

## Java

- **`.class` files** show the outline of their source: the declaration,
  generic members, constants, `module-info`, and the Java release they were
  compiled for -- class-file version 52 is Java 8, 65 is Java 21 -- with
  preview features marked.
- **`.jar`, `.war` and `.ear`** show above their contents what the manifest
  says (the class it runs, the module, the version), the Maven artifact it was
  built as, its `module-info`, and which Java its classes need, newer-release
  classes counted apart. A `.war` lists its web parts, an `.ear` its modules.
- A signed jar says who signed it and whether the signature still holds; one
  whose manifest was changed after signing is reported. Each file's own
  digest is not checked -- that reads every byte -- and the page points to
  `jarsigner -verify` for it.
- **Key stores** -- `.jks`, `.jceks`, `.keystore`, `.ks`, `.truststore`,
  `.p12`, `.pfx` -- show their aliases and certificate chains: subject, issuer,
  validity, key, signature, alternative names, fingerprints. No password is
  asked for; the defaults (none, `changeit`) are tried, and the page warns
  when one opens the store. Keys are never decrypted.
- **`.properties`** files show their keys and values as Java reads them, with
  duplicates and broken escapes marked, and the encoding and locale named.
- `.ear` archives get the listing and Extract, as `.jar` and `.war` do.

## Certificates and keys

- PEM and DER certificates, bundles, signing requests, revocation lists,
  PKCS#7, private and public keys, and OpenSSH keys and certificates show what
  they hold: who, issued by whom, valid when, the key, the fingerprints.

## Programs, apps and installers

- **Programs and libraries** -- Mach-O, ELF, Windows `.exe` and `.dll`, `ar`
  and `.lib` archives, COFF objects -- say what they are, where they run, what
  they link, and whether their signature (a code signature or Authenticode)
  holds. **Scripts and batch files** say what runs them, and what would stop
  them from running.
- **App bundles** and other code bundles show their identity, signature,
  notarization ticket, a check of every sealed file, the permissions they ask
  for, the code inside, and where they came from.
- **Installer packages** (`.pkg`, `.mpkg`): the signature checked, a stapled
  ticket, what the installer shows, the scripts it runs, every file it
  installs, and the ones worth a look.
- **Disk images**: compressed, sparse, ASIF and ISO images, their partitions,
  and the top folder of an APFS or HFS+ volume inside -- without mounting
  them. A signature is checked in the background; an encrypted image is
  recognised.
- **Crash reports** (`.ips`) say in words what stopped the program, and show
  the thread that crashed with the program's own frames picked out; the
  other threads and the loaded images are folded away.
- **Provisioning profiles** (`.mobileprovision`): the app, team, kind, expiry,
  devices, entitlements and certificates, the signature checked offline.

## E-mail and web locations

- **`.eml`, `.emlx` and `.mbox`** show the messages, their attachments and
  forwarded messages. They warn of failed sender authentication, a Reply-To
  that goes elsewhere, links that say one address and go to another, and
  attachments that run code.
- **Web locations and shortcuts** (`.webloc`, `.inetloc`, `.url` and kin) show
  where they really go and which app opens them, with a warning for a
  misleading or dangerous address.

## SQLite databases

- **Space** shows each table and view, its row count, a few rows and its
  schema.
- **Right-click ▸ Edit** opens a **Database window**: the tables and views in
  a sidebar, the rows fetched as you scroll, sorted by clicking a column,
  filtered by text or by a SQL condition, the selected row's values in full
  below. ⌘C copies rows; **Export CSV** writes them all. **Query** runs a
  `SELECT` of your own.
- The database itself is never opened: a copy of it, with its `-wal` file, is
  read. Changes an app has not yet written into the main file show, and the
  app is not disturbed.

## Coloured source code

- **Space on a source file** shows it coloured, with line numbers, light or
  dark as the Mac is. **Text Edit** colours the same files, and after an edit
  recolours only the lines it changed.
- Over sixty languages, by the TextMate grammars Visual Studio Code ships,
  now part of Diptych. The language is told by the name, the extension, or
  the first line (`#!/usr/bin/env python3`).
- JSON, XML, YAML, TOML and property lists keep the colouring they had, which
  also pairs brackets and tags. HTML is still shown as the page.
- A very large file is coloured in Quick Look for up to two seconds, and the
  page says where the colours stop; Text Edit goes on colouring in the
  background until it is done. A line over 10,000 characters -- a minified
  file -- is left plain.
- Each grammar's licence is in **Diptych ▸ Acknowledgements…**.
- **JSON and XML have a Format button** in Quick Look: one value or element
  to a line, indented, and **Show as Written** to go back. A file written as
  very long lines opens formatted. JSON keeps its keys in their order, its
  numbers and escapes as written, and its comments; XML never reads an
  external DTD or entity.

## Folder sizes are kept

- What **Calculate Directory Sizes** (∑) works out is kept, with when it was
  measured and whether it was finished or still growing then. A folder
  measured before shows its size again -- in a later session too -- teal if
  it was finished, orange if it was caught part way, and fainter as it ages,
  since it was true when it was measured and not necessarily now.
- **Settings ▸ Behaviour ▸ Folder Sizes** says for how long: a week unless
  changed, from a day to 90 days. After that a size is no longer shown, and
  is deleted. *Forget All Sizes* there, and View ▸ Clear Directory Sizes,
  forget them at once.
- ∑ measures again, the folders already measured included, showing the kept
  size until each folder has been read. The Info window says how long ago a
  size was measured; sorting by Size uses the kept sizes too.

## A folder in a Git repository

- With version tracking on, Space on a folder adds what Git knows: the
  branch, the branch it follows and how many commits are unsent or waiting
  to be fetched, the uncommitted changes -- the folder's own, when it is not
  the repository's top -- and the last few commits.

## Icons

- **View ▸ as Icons** (`⌃⌘1`) shows a pane as big icons in name order; **as
  Placed Icons** (`⌃⌘2`) where Finder last put them; **as List** (`⌃⌘3`)
  goes back. Each pane of each tab has its own.
- Selecting, the right-click menu, renaming, the keys, dragging and dropping
  all work as in the list; a rubber band selects.
- An icon moved by hand is written to the folder's `.DS_Store`, so Finder
  shows it there too. **View ▸ Clean Up** puts the placed icons back on the
  grid.

## The journal

- Diptych remembers what it did, for 90 days: every copy, move, rename,
  trashing, deletion and change, on this Mac and on servers, every undo and
  redo, every run, every batch an agent or a shortcut proposed and you
  executed -- with each file's place before and after.
- And everything else, by category: files opened and previewed, folders
  opened, navigation, settings (what changed, from what to what), windows,
  runs, Diptych starting and quitting, and every request from an agent or
  Shortcuts. **Settings ▸ Behaviour ▸ Journal** leaves any category out.
- Only what was settled on: a selection is recorded once it has stood for
  three seconds, a preview once it has been shown for a second and a half.
  Running the arrow keys down a folder is not two hundred entries.
- **Window ▸ Journal** (`⌥⌘J`) searches it by any word, period, category,
  kind, or who did it; **Statistics** sums it up. A row shows where its file
  was and where it is now. Nothing is undone from it.
- It is kept in `~/.diptych/journal.sqlite`, readable only by you. Agents and
  shortcuts can read it, never change it.

## Siri, Shortcuts and Spotlight

- Diptych's agent commands are **App Intents** as well: Siri, the Shortcuts
  app and Spotlight can list windows and panes, get the files shown or
  selected, read comparisons and runs, show folders, change the curated
  settings, and search the journal. Off until **Settings ▸ Agents ▸ Allow
  Siri, Shortcuts and Spotlight to use Diptych** is ticked.
- Files are never changed from there: copies, moves, trashing, deletions and
  renames are only proposed, in the review window an agent's batch opens.
  Nothing is run. Every request shows in the activity console.
- Siri knows ten of them by phrase, *"What's selected in Diptych"* among them.
- Two Spotlight switches, both off at first: **journal entries** -- typing
  *moved tax* finds the move -- and **records for the files Diptych shows**,
  carrying what Spotlight does not know by itself: the town a picture was
  taken near, the camera, lens and date, the tags. Typing *Budapest* then
  finds the pictures taken there.

## Apple Intelligence explains comparisons

- With Settings ▸ **Use Apple Intelligence** on, **Compare Folders** shows a
  box between the checkboxes and the list that says in a few sentences what
  was added, removed or changed, and any pattern, such as one side being a
  newer copy. It is asked in the background each time a comparison finishes,
  Refresh included; the list can be used while it is on its way.
- The model gets file names, sizes, dates and which properties differ, never
  what is in the files. A folder found on one side only is described once,
  not file by file.
- **Comparing two files**, a box under the line with find and the count of
  differences explains what the changes mean -- a value changed, a section
  added -- rather than repeating the lines. The model reads the diff: each
  change with two lines around it, up to about 6,000 characters, and half as
  much if that is still too much for it.
- It is asked again when the comparison changes: *ignore spacing*, a file
  changed elsewhere, or a pause of a second and a half in typing on the
  unlocked side.
- Everything here uses the system model on this Mac, named explicitly, never
  Private Cloud Compute, so nothing is sent anywhere. With **Use Apple
  Intelligence** off, the comparison windows show no box.

## New from Clipboard

- With *Save a picture as* set to **Ask each time**, the dialog offers first
  the format most pictures in the folder already are -- PNG, JPEG or PDF -- and
  Return chooses it. A folder with none of them still offers PNG.
- With Apple Intelligence on, pasted text is saved as `.md`, `.json`, `.yaml`,
  `.csv`, `.sh`, `.py`, `.swift` and so on, from what the model on this Mac
  says the text is, instead of always `.txt`.

## Scripts with Apple Intelligence

- **Get Scripts** has four new ones: *Explain with Apple Intelligence* (a
  report beside a PDF), *Summarize with Apple Intelligence*, *Suggest a Name
  with Apple Intelligence* and *Describe with Apple Intelligence* (pictures).
- They use `fm`, the Foundation Models command line of macOS 27, always with
  the model on this Mac. Run `sudo fm license` once before the first use. They
  run only when you run them.

## Archives

- **Dragging out of an opened archive** -- to Finder, the Desktop, another
  app -- hands over a clean copy with the archive's own permissions and
  quarantine, not Diptych's locked one. It is made in an instant, as an APFS
  clone, and dropped back into Diptych it counts as the archive's item.
- **Copy and paste** does the same: ⌘C on an archive item, and another app's
  paste gets a clean copy, made at the paste; Diptych's own paste copies from
  the archive. At quit, copies still on the clipboard are made before the
  opened archives are cleared away.
- An archive deleted or changed while open takes its panes with it: they step
  out to where it was, and Back and the recent folders skip the stale copy.
- A drop out of an archive always copies; a copied app keeps a valid
  signature. Read-only folders that hold symbolic links copy whole, and
  archives with read-only folders open again.
- Diptych no longer leaves a `__DIPTYCH.json` file in every folder of an
  opened archive or a server's cache: what it knows of them is kept in
  `~/.diptych/cache.sqlite`.

## The sidebar

- Each volume's size and free space is asked of it in the background, apart
  from the others. A disk slow to answer -- a Time Machine disk during a
  backup, a disk spinning up, a server gone quiet -- shows `??` until it does,
  and the sidebar, the other volumes and the panes no longer wait for it.

## Servers

- A folder gone from the server is removed from its cache, unless it holds
  edits not sent yet. An answer from the server is no longer retried as if
  the connection had dropped.

## Text Edit

- A toolbar button shows **invisible characters**, framed; it is on by
  default when a file has any. A byte-order mark shows and can be deleted, and
  deleting it counts as a change to save.

## Also

- Scripts that explain PDFs read scanned pages too, by text recognition.
- The Runs window's progress bar knows how long each script usually takes.
- ⌥⇥ brings the smaller windows -- Info, Compare, Text Edit, Runs, the
  Journal -- forward together, and the two-pane windows take the keyboard from
  behind them rather than covering them.
- The Window menu's list of windows no longer flickers or empties.
- Column widths are saved only while you drag a divider.
- A command run in the terminal reports its exit status correctly: it was
  sometimes 0 for a command that failed.
- MCP's `get_pane` says when a pane is loading, moving or opening an archive;
  `set_pane_view` shows it as icons or a list.

## Diptych's records in one database

- The windows and panes as they were left, where trashed files came from,
  the servers connected to, how long scripts take, and the scripts approved
  are kept in `~/.diptych/diptych.sqlite`, readable only by you, instead of
  five JSON files. `config.json` stays a file, to be edited by hand.
- **`DIPTYCH_STORAGE.md`**, in the source, says what every file in
  `~/.diptych` is, since which version, and what replaced the ones gone.
- A server's keep-alive interval and the checksum command it was found to
  have are no longer forgotten at every start.

## Upgrading

At its first start, Diptych brings `state.json`, `trash-origins.json`,
`servers.json` and `scripts-approved.json` from `~/.diptych` into
`diptych.sqlite` and deletes them; a file it cannot read is left where it
was. Nothing else to do, unless you used an SFTP server with 1.13: before installing
2.0.0, let every edit made to a server's file reach the server, quit
Diptych, and delete `~/Library/Caches/dev.verhas.Diptych/Opened Servers`.
2.0.0 does not read 1.13's record of what was fetched there: it would empty
the fetched files -- an edit not yet sent among them -- and show a stray
`__DIPTYCH.json` in every folder. Everything is fetched again when needed.

Opened archives are unpacked afresh, as always. The Siri, Shortcuts and
Spotlight switches, and Apple Intelligence, are off until you turn them on. A
*Save a picture as* setting other than *Ask each time* is used as before.
