# Diptych 1.7.1

Files in Dropbox and other cloud folders go to the Trash when their provider
holds back, copying a name or a path says what was copied, and an error can
be copied as text.

---

## Trash in cloud folders

- **A file Dropbox refuses to trash is moved to the Trash anyway.** For some
  items it has long had, Dropbox turns down its part of a move to the Trash,
  and macOS reported that as "you don't have permission". Nothing on the disk
  objects to the move, so Diptych now makes it directly. Undo puts the file
  back where it was; Finder's Put Back does not know where that is.
- **A cloud file is given time to leave.** When a move to the Trash reported
  success but the file was still in its folder, Diptych took it as a failure
  at once and removed the copy that had reached the Trash. A cloud provider
  can finish a moment later, which could have left no copy at all. Diptych now
  waits a little, and for a cloud file never removes what is in the Trash.

---

## Copying

- **Copy Name and Copy Path say what they copied** — "Copied path:
  /Users/…/report.pdf" — exactly as it went to the clipboard. A long one keeps
  its start and end, with an ellipsis between.
- **Error messages can be copied.** The text of an error can be selected, and
  the dialog has a Copy button for the whole of it. The red results in the
  File Operations window and the list of script problems can be selected too.

---

## Upgrading

Nothing to do.

---

*829 tests.*
