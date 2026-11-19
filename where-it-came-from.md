# Where a file came from

Not a file format, so not part of `PREVIEW-FORMATS-2.0.md` (item 17 there,
moved here). Every file can carry its history in extended attributes,
whatever its format: where it was downloaded from, which app saved it,
whether macOS still holds it in quarantine. That cuts across all the
previews -- and the Info window -- rather than being one more of them.

Status: `done`, in 2.0.0. `FileOrigin` reads it; Quick Look and the Info
window show it.

## What was there before

- **Info window, Spotlight section** (`FormatDetails.spotlight`):
  `kMDItemWhereFroms` as "Came from".
- **Info window, extended attributes** (`InfoView`): every attribute listed;
  text values editable; `com.apple.provenance` described in words
  (`Provenance`), with the app it points to looked up -- as administrator,
  on request, remembered in `~/.diptych/provenance.sqlite`.
- **App bundles** (`AppBundle`, `BundleReport`): quarantine (which app, when,
  opened yet) and the download addresses, in the bundle preview's origin
  part.
- **Flat view and agents**: `xattr(...)` in filter expressions, and the
  agent instructions name the attributes.

These stay: the Attributes tab is where attributes are edited, the
Spotlight list shows what Spotlight knows, and the bundle preview keeps its
own origin part, which also says whether an app runs translocated or came
from the App Store.

## What was made

One account of a file's origin, `FileOrigin`, read from the attributes once:

- [x] `com.apple.metadata:kMDItemWhereFroms`: the download address and the
      page it was linked from, as links
- [x] `com.apple.quarantine`: quarantined or not, by which app, when, whether
      it has been opened since (flag `0x40`)
- [x] `com.apple.provenance`: which app made or changed it, in the words of
      `Provenance` -- the lookup made as administrator if it was, otherwise
      the installed apps with the same tag
- [x] Other extended attributes: listed by name and size; the Finder's own
      (`FinderInfo`, the resource fork, tags, last-used date) left to the
      other tabs
- [x] Plain warnings: downloaded and never opened; downloaded from a site
      whose name is spelled in punycode, decoded so the lookalike letters
      show

## The questions, settled

- **Where it is shown.** Both, from the one model: a section, *Where it came
  from*, at the end of every Quick Look page Diptych makes, and a panel on
  the Info window's General tab.
- **When.** Quick Look adds the section only for a file that came from
  elsewhere -- with a download address or a quarantine. Nearly every file an
  app writes carries a provenance tag, so that alone would put the section
  under every preview. The Info window shows the panel for any file with
  anything attached.
- **Files Quick Look previews itself** -- an ordinary PDF, a picture: only in
  the Info window. The panel shows Quick Look's own preview, which Diptych
  cannot add to.
- **Folders**: no section in Quick Look; an app bundle's page has its own
  origin part.
- **Files inside an opened archive** carry the archive's quarantine, put on
  when it was unpacked: said so, naming the archive, and the "never opened"
  warning is not given for them.
- **A file on a server** (an SFTP server's fetched copy): nothing, rather than
  "no origin" -- its attributes would say how Diptych fetched it.
