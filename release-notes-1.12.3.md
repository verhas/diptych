# Diptych 1.12.3

A light or dark **theme** that every window follows, two **VT100** terminal
schemes, tidier **New** and **Paste** submenus, a **Reveal in Finder** that
always reaches the real Finder, and a single-pane mode that no longer reaches
into the pane that is not on screen.

---

## A theme for every window

- Settings ▸ **Appearance** ▸ **Theme**: *Follow the system*, *Light*, or
  *Dark*. Light and dark override the Mac's own setting, so a dark Diptych can
  sit on a light desktop or the other way round.
- It is applied to the **whole application**, so every window follows it at
  once -- the panes, and Text Edit, Bin Edit, Release Notes, Get Info, Compare,
  Rename Many and Settings too, which until now opened in the system appearance
  whatever the setting said. Changing it recolours the windows already open.

## Terminal: the VT100 schemes

- Two more terminal colours in Settings ▸ Appearance, beside Light, Dark and
  Custom: **VT100 Green** and **VT100 Amber** -- the single-phosphor green and
  amber of the 1970s video terminals, on black.

## New and Paste, as submenus

The right-click menu had grown long, so two groups fold up:

- **New** ▸ Folder, File, from Clipboard.
- **Paste** pastes on a click; its arrow opens **as Link** and the former
  **Paste Special** properties, which no longer take a top-level entry of their
  own. (In the empty-space menu, where AppKit will not let one item both paste
  and open a submenu, the paste sits inside the submenu; ⌘V pastes directly
  regardless.)

## Reveal in Finder reaches the real Finder

- With *Show files in Diptych instead of Finder* turned on, other apps' "Reveal
  in Finder" rightly open Diptych -- but Diptych's **own** Reveal in Finder used
  to open another Diptych. It now tells Finder by name, so everything else opens
  Diptych while Diptych itself still reaches the real Finder.

## Single-pane mode leaves the hidden pane alone

- With only one pane on screen, the hidden pane is no longer consulted or acted
  on. **Copy to Other Pane**, **Move to Other Pane** and **Extract to Other
  Pane** are disabled -- there is no visible pane to send to.
- **Compare** (⌘D) no longer puts the selected file beside whatever happened to
  be selected in the pane you cannot see. Two items selected in the one pane
  compare with each other; a single item compares with its own **committed
  version in Git** -- the uncommitted changes, read locally with no fetch and no
  server. A file Git does not track, or a folder, has no committed version and
  Compare says so instead.
- **MCP** `list_windows` now reports whether a window is in single-pane mode,
  and scripts get **`DIPTYCH_SINGLE_PANE`** (`1`/`0`) beside the pane paths, so
  an agent or script knows `DIPTYCH_OTHER` is a pane the person cannot see.

## Upgrading

Nothing to do.

---

*1460 tests.*
