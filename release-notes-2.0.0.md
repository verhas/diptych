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
arrives as a **clean copy**.

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

## Upgrading

Nothing to do. Opened archives and servers' caches are listed afresh into the
new database the first time they are opened. The Siri, Shortcuts and
Spotlight switches are off until you turn them on.
