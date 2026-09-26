# Diptych 1.3.2

A window that looked closed turns out to matter more than it seemed: fixing
that properly fixed two separate bugs at once. Alongside it, a Tip of the Day,
release notes that show themselves, and half a dozen smaller fixes.

---

## A closed window is closed

Reopening Text Edit, a two-file comparison, or Compare Folders on the same
thing after closing it could still show what was on disk the *first* time,
even after an edit made elsewhere. The previous attempt at this — reload
whenever the window's delegate looked unfamiliar — assumed a reopened window
is always a fresh `NSWindow`. It is not: ⌥Tab cycling back to windows that had
already been closed was the giveaway. SwiftUI's own `WindowGroup(for:)` can
keep a closed window's state, delegate included, ready to hand back the next
time the same value is opened.

Two fixes, for the two things that turned out to be true at once:

- **Asking to open a file or a pair again now reloads it directly**, at the
  moment you ask, rather than trusting that whatever window comes back has
  actually reset itself. Text Edit, the two-file comparison, and Compare
  Folders all work this way now — the reload happens whether the window is
  genuinely being created fresh or merely being shown again.
- **⌥Tab no longer cycles back to a window you have closed.** Windows are now
  dropped from the rotation the moment AppKit says they closed, rather than
  waiting for the object behind them to be deallocated, which is exactly the
  event a lingering scene can indefinitely postpone.

---

## A tip at startup

A small dialog, once each time Diptych starts, with one fact about using it —
a shortcut, a checkbox, something a menu doesn't explain on its own. **Next**
moves to another; **Do not show tips at startup** turns it off, and Settings ▸
Behaviour turns it back on.

---

## Release notes that show themselves

Every release's notes are now built into the app itself, newest first, and
the first launch of a new version shows them once, automatically — rendered
the way a README is, not as raw asterisks and hash marks. `build.sh` now
refuses to build a disk image at all if the release notes for the version
being packaged don't exist yet, or don't match it, which is what stops one of
these from ever going out stale.

---

## Fixes worth knowing about

- **Quitting can stop asking.** The "Quit Diptych?" dialog has its own **Do
  not ask anymore** checkbox now, alongside the one in Settings.
- **A Markdown preview no longer leaves a stray mark behind a horizontal
  rule.** Foundation's own parser gives a `---` a placeholder character
  purely to have something to attach the rule to internally; printing that
  character as well as the rule left an odd "⸻" sitting after every one, in
  Quick Look's rendering of any Markdown file, README included.
- **An application is a folder to walk into, not something Diptych launches**
  on a click or a Return — **Run App**, in its own right-click menu, is the
  deliberate way to start one instead.
- **A file Diptych cannot read says so**, instead of calling it binary and
  pointing at Bin Edit, which needs the same permission and would refuse it
  too.
- **Move to Trash notices when it didn't work.** A handful of files macOS
  protects — inside `/System`, mostly — used to report success while quietly
  staying exactly where they were; Diptych now checks and says so.

---

## Upgrading

Nothing to do. The version Diptych now remembers having shown release notes
for lives in its own file under `~/.diptych`, apart from Settings, so nothing
here is reset by anything in the Settings window.

---

*742 tests.*
