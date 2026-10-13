# Diptych 1.9.1

A click that slips no longer moves anything, a transfer asked for again is not
queued again, and the transfer panel can always be put away. The MCP token is
hidden in Settings, and can be copied and pasted.

---

## Settings

- **The MCP token is hidden** as `••••••••-••••-…`; the eye beside it shows
  it. A copy button copies it, and another the port. The token can be typed or
  pasted -- only a UUID is taken.
- **A click outside a text field ends the typing in it.** The caret stayed in
  the last field edited, so a key pressed later -- Delete, say -- went to a
  field that looked done with.
- **The sounds line up**: the pickers start in one column, not after each
  name.

---

## Fixes

- **A click that slipped could move files.** A name clicked on a few times
  often drags a few points; that drag could end on the folder row next to it,
  or hold long enough for a folder to spring open, and drop there. On a share
  you may not write to it showed as a permission error out of nowhere; where
  you may, the move was made -- Edit ▸ Undo or Redo Many… lists it, until
  Diptych quits. A drag that never goes further than 40 points from where it
  started, in its own pane, is now a click: it neither drops nor opens
  folders.
- **Refresh in the toolbar refreshes the active pane**, as `⌘R` does, not
  both.
- **The rows no longer jump on Refresh.** The spinner made the path bar taller
  while it showed; it has its own place now, and shows only for a listing that
  takes more than half a second.
- **A folder nudged while being clicked started to move into itself.** It
  landed on its own row, which is a folder to drop into, and the move began --
  on a server, with a long wait while the folder was measured -- before it
  failed. A folder dropped on itself or into a folder inside it now slides
  home, as a file dropped back into its own folder does; dropped there
  deliberately, it says *A folder cannot go into itself*.
- **The same move could be queued several times.** Grabbing a folder three
  times queued three moves of it. What is already waiting to be moved, or being
  moved, is not moved again, and what is waiting to be copied to a folder is not
  copied there again: *Already being moved*, *Already being copied there*.
- **The transfer panel could stay on screen for good.** It waited for both
  panes to be listed again after the copy, and a server that had stopped
  answering never finished that listing. The panel now goes as soon as the
  copying is over, the listing is waited for three seconds at most, and the
  panel's **×** hides it at any time while the transfer goes on.

---

## About

Diptych ▸ About Diptych has the new slogan: *the agentic Swiss pocket knife of
file managers for macOS*.

---

## Upgrading

Nothing to do.
