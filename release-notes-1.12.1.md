# Diptych 1.12.1

A Trash that behaves like Finder's: **Put Back** now works for anything in the
Trash, not only what Diptych trashed; **Delete Immediately** and **Empty Bin**
are here; **Rename** is back on the Trash menu; and the per-volume bin button no
longer looks like a way to throw the whole disk away.

---

## The Trash

- **Original Location is filled for every trashed file now**, not only the ones
  Diptych trashed. For anything Finder or another app put there, Diptych reads
  Finder's own "Put Back" record -- which macOS keeps privately inside the
  Trash's `.DS_Store`, with no public API -- using the Full Disk Access it
  already asks for when a Trash is opened. It only ever reads that record and
  never writes it; the most that can go wrong is a dash, or rarely a wrong path,
  never a crash and never a move you did not confirm.
- **Put Back** -- renamed from "Restore to Original Location", as Finder names
  it -- therefore works for those files too, recreating a folder that has gone
  and stepping past a name taken in the meantime rather than overwriting it.
- **Delete Immediately** removes the selected items for good, and **Empty Bin**
  clears the whole Trash the pane is showing. Both ask first, because neither
  can be undone.
- **In the Trash, the trash keystrokes delete for good.** `⌫`/`⌦` and
  `⌘⌫`/`⌘⌦` no longer try to re-trash what is already in the Trash -- which
  failed, saying the folder could not be written to -- but run Delete
  Immediately instead, still with the confirmation that permanent deletion
  deserves.
- **Rename** is back on a trashed file's right-click menu, as it is in Finder.
  Renaming a file in the Trash keeps its Put Back location.
- **The sidebar's per-volume bin button** is now a deleted-items bin rather than
  a bare trash can, so it reads as "open this disk's Bin" and not "throw this
  disk away". It is hollow on a read-only volume, whose Bin is always empty, and
  solid otherwise -- the same size either way, so the volume names stay lined
  up.

## Upgrading

Nothing to do. The first time you open a Trash, macOS asks for Full Disk Access
and relaunches Diptych; grant it once and the Original Location column fills in
for everything, whoever did the trashing.

---

*1446 tests.*
