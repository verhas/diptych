# Diptych 1.3.1

One fix: a comparison window left open, or reopened, across an edit made
somewhere else no longer goes on showing what it read the first time.

---

## A comparison notices when a file changes

Compare two files, edit one of them — in Text Edit, in another app, from the
command line — and the open comparison window kept its original verdict
forever, "these are the same" included, however different the files had since
become. `reload()` already existed for exactly this. Nothing was ever calling
it.

The window now watches both files while it is open and reloads on its own
when either changes, the same way a pane notices a folder changing under it.
Two things it deliberately does not do:

- **It never discards unsaved typing.** If you have unlocked a side and typed
  into it, an edit made to the other file elsewhere is picked up as before,
  but a change to *your* side leaves your typing alone — the existing "this
  file changed since you started editing it" warning at Save time is still
  what settles that, rather than an automatic reload settling it for you by
  throwing your work away.
- **It survives the file being replaced outright**, not just edited in
  place — which is how this app's own Save, and many editors, actually write
  a file: to a temporary name, then swapped into place. The old file the
  window was watching is gone at that point, not merely changed, and the
  watch is re-established on whatever replaced it rather than going quiet.

---

## Upgrading

Nothing to do.

---

*730 tests.*
