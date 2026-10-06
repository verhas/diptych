# Diptych 1.6.1

Symbolic links tell the truth about what they point to, a broken one is
marked and offers only what can work on it, and drag and drop puts a file in
the folder you drop it on.

---

## Symbolic links

- **A broken link has a red dot** beside its arrow — its target is not there.
- **Its right-click menu offers only what can work.** Open, Text Edit, Bin
  Edit, Copy ▸ Content and Rename with Suggested Name all need the target, so
  they are left out. Rename, move, copy, trash and Reveal in Finder act on the
  link itself and stay — and so does Get Info, where a new target can be typed
  to repair the link.
- **Go to Link Target**, first in a link's right-click menu, opens the target's
  folder with the target selected. It is there only when the target exists,
  and goes one step: a link to a link lands on that link.
- **The executable badge follows the target.** A link to a PDF no longer
  shows as a program because the link's own bits say so.
- **No permissions are shown or edited for a link.** On macOS a link's own
  bits are always `rwxr-xr-x` and govern nothing; its target's are what count.
  Editing a selection that mixes links and files changes only the files.
- **A broken link keeps its name.** Paste as Link beside one used to pick that
  very name and fail; now it takes the next free one, as for any other file.

---

## Drag and drop

- **Drop on a folder, and the file goes into that folder** — without waiting
  for it to spring open. A drop before the folder opened could land in the
  pane's own folder instead, which, when the file was already there, did
  nothing but say so.
- **A folder stops flashing when the drag ends.** After a drop onto it, a
  folder could go on flashing for a minute, even after leaving it and coming
  back.
- **An app is not a folder to drop into.** A file dropped on an app goes into
  the pane's folder, not inside the app.

---

## Upgrading

Nothing to do.

---

*809 tests.*
