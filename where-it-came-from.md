# Where a file came from

Not a file format, so not part of `preview-formats-2.0.md` (item 17 there,
moved here). Every file can carry its history in extended attributes,
whatever its format: where it was downloaded from, which app saved it,
whether macOS still holds it in quarantine. That cuts across all the
previews -- and the Info window -- rather than being one more of them.

Status: `planned`. Not scheduled for a release yet.

## What is already there

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

So the pieces exist, scattered: the bundle preview has the only "origin" a
preview shows.

## What is wanted

One account of a file's origin, made once and shown wherever it helps:

- [ ] `com.apple.metadata:kMDItemWhereFroms`: the download address and the
      page it was linked from, as links
- [ ] `com.apple.quarantine`: quarantined or not, by which app, when, whether
      it has been opened since (the bundle preview's reading, made general)
- [ ] `com.apple.provenance`: which app made or changed it (`Provenance`)
- [ ] Other extended attributes: listed by name and size
- [ ] Plain warnings where they matter: downloaded and never opened; came
      from a site that only looks like a familiar one (`Punycode`, as the
      web-location preview warns)

## Open questions

- Where it is shown. A section at the end of every Quick Look report; a
  part of the Info window that replaces the scattered rows above; or both,
  from the one model.
- Files with no report of their own -- an ordinary PDF, a picture -- that
  Quick Look previews natively: an origin line over the native preview, or
  only in Info.
- Files inside an archive opened as a folder carry the archive's quarantine
  (put on when unpacked): say that it is the archive's, not the file's own.
- A file on a server has none of these attributes: say nothing, rather than
  "no origin".
