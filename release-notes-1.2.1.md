# Diptych 1.2.1

Fixes for what 1.2.0 got wrong, all of it found by using it on macOS 27.

---

## Quick Look follows you again

**`..` is previewed as the folder it is.** Arrowing onto it emptied the panel
and shut it — a regression in 1.2.0, where the preview was handed the selection
with `..` filtered out. Diptych previews a folder by listing it, which is
exactly what somebody about to go up wants to see.

**Walking into a folder keeps the preview open**, with the cursor on the
folder's first item, so it follows you through the tree instead of stopping at
the door.

---

## The first click lands

Up, Back, Forward and the path bar appeared not to work at all while a preview
was open: they needed **two** clicks, and the first seemed to be swallowed.

The panel is the key window while it is up, so a click into the pane window is
a click into a *background* window. macOS spends such a click on making the
window key and only delivers it to views that accept a "first mouse" — a table
row does, which is why selecting a file still worked, and a button does not.
Diptych now makes the window key from the click monitor, which sees the event
before it is dispatched, so the same click reaches the button. The preview
stays open, as it does when a row is clicked.

---

## The menu for the empty space

Right-clicking **below the last row** produced no menu at all. SwiftUI's
selection-based menu is only ever consulted for rows, and a plain context menu
on the table is not consulted at all — so the folder's own commands now come
from AppKit, put up by the same monitor that watches the mouse:

**New Folder**, **New File**, **New from Clipboard** (when it is switched on),
**Paste**, **Paste as Link**, **Rename Many…**, **Select All** and **Refresh**.
It activates the pane you right-clicked. On a row, the file menu answers as
before.

**New Folder** also joins New File in the menu for a file, where it was missing.

---

## macOS 27

Apple Intelligence now reports "more than the model can read at once" through a
different error, so a long excerpt was shown as an unexplained failure in
Apple's words instead of Diptych's message — the one that says to set fewer
characters in Settings, under Apple Intelligence. The test that sends the model
60,000 characters caught it.

---

## Upgrading

Nothing to do, and nothing to decide: this release only fixes things. Settings
carry over untouched.

---

*671 tests.*
