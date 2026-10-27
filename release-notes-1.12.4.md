# Diptych 1.12.4

**New Tab** (⌘T) opens the tab straight into the window you are in, without
first showing a separate window or moving and resizing the one you started
from. The new tab also starts with that window's layout.

---

## New Tab, without the shuffle

- ⌘T used to open an ordinary window beside yours, then pull it into your
  window as a tab a moment later. On the way, the new tab could put back the
  size and position some earlier window had been saved with -- and because the
  tabs in one window share a single frame, your window moved and resized with
  it, sometimes more than once, and kept that frame afterwards.
- The tab now joins your window before it is ever shown. Your window stays
  exactly where it is, at the size it is.

## A new tab looks like the window it came from

- A new tab starts with the **sidebar**, **single or dual pane** and **hidden
  files** of the window you pressed ⌘T in. Until now it took them from
  whichever window had last used the same saved slot -- so a tab could come up
  in single-pane mode for no visible reason, and once there were more tabs
  open than ever before, each further one opened without its sidebar.
- The folders a new tab shows still come from its saved slot, as before.

## Upgrading

Nothing to do.

---

*1460 tests.*
