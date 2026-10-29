# Diptych 1.12.5

Renaming in place now works with the function keys: **F4**, **F5**, and
**F6** no longer need a second click after the name. A new setting turns off
renaming by clicking a name, for people who click names by accident.

---

## F4, F5 and F6 while renaming

- While you are typing a new name in a row, **F5** copies and **F6** moves the
  selection to the other pane, and **F4** edits its permissions. Each one first
  commits the name you have typed, then does its job on the file under its new
  name.
- Before, the name field took these keys and nothing happened. You had to click
  again after the name and press the key a second time.
- If the rename fails, Diptych shows the error and the copy, move, or permissions
  edit does not run.

## Rename on a click on the name

- Settings ▸ **Behaviour** ▸ **Rename on a click on the name**, on by default.
  Turn it off, and clicking the name of a selected file only selects it.
- **F2** and the right-click menu rename either way.
- The setting is also available to MCP clients through `set_setting`.

## Upgrading

Nothing to do. The setting is on, so clicking a selected name still renames as
it did before.

---

*1460 tests.*
