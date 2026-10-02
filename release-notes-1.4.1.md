# Diptych 1.4.1

The update check now actually tells you about an update, and there is a menu
item to ask for one. Right-click menus show their keyboard shortcuts, Copy
can copy what is inside a file, and New from Clipboard has its name ready
sooner.

---

## The update check that said nothing

1.3.3 and 1.4.0 checked GitHub at startup, found the newer release, and then
kept quiet about it. If "Did You Know?" tips were switched on, the tip took
the window's one dialog while the check was still waiting for GitHub's answer.
When the answer arrived the dialog was taken, so the notice was dropped. The
check had already counted as done for the day, so the same thing happened the
next day, and every day after.

A notice that arrives while another dialog is open now waits, and appears as
soon as that dialog is closed.

**If you are on 1.3.3 or 1.4.0 with tips switched on**, your copy has probably
never offered you an update.

---

## Check for Updates…

**Diptych ▸ Check for Updates…**, between About and Settings, checks right
away, whatever the startup setting says. It tells you either way: a newer
version to download, that you are up to date, or that GitHub could not be
reached.

The startup check is now in **Settings ▸ Behaviour ▸ Check for updates**:
once a day at most, ask at startup, or never on its own. Until now the only
way to change your answer to the startup question was to edit `config.json`.

---

## Shortcuts in right-click menus

The right-click menus now show the same shortcuts the menu bar does. This
applies to the menu on a file and to the menu on the empty space below the
list. Where the key that does the same thing is not a menu-bar shortcut, the
menu shows that key instead:

- **Rename…** shows F2.
- **Move to Trash** shows ⌫. It asks before trashing, as ⌫ does; the menu
  bar's ⌘⌫ trashes without asking.

**Rename Many** had two shortcuts assigned to it, ⌃⌘R and ⇧⌘R. It now has
only ⌃⌘R, the one the menus always showed.

---

## Copy ▸ Content

The right-click **Copy** submenu now has **Content** next to **File Name** and
**Full Path**. It is also **Edit ▸ Copy Contents**, ⌃⌘C. It puts what is
inside the file on the clipboard, not the file itself:

- A text file is copied as text, ready to paste into any editor.
- A picture or a PDF is copied as itself. Its original format is kept, and a
  TIFF copy is added for apps that only read TIFF.
- Several text files are copied one after another, each starting on its own
  line.

It is the reverse of **New from Clipboard**.

It appears only when it can work. For a folder, an archive or any other binary
file, a selection of several pictures, or more than 32 MB, the item is left out
of both menus.

---

## New from Clipboard names its file sooner

With Apple Intelligence switched on, New from Clipboard asks the model for a
name, which takes a second or three. Diptych now starts asking when New from
Clipboard looks likely, instead of waiting until it is chosen:

- when you copy something while Diptych is in front,
- when you switch to Diptych after copying something elsewhere,
- when you open a menu, either in the menu bar or with a right-click on a pane.

When you then choose the command, the name is ready or nearly ready. If the
clipboard, the folder or the naming settings changed in the meantime, the early
answer is thrown away and the command asks the model as it always did. Only
Vision's reading of a picture is kept in that case, since it does not depend on
the folder and is the slower half of naming a picture.

This happens only while Diptych is in front, and never when the clipboard
holds files: after copying files, the next step is Paste. **Rename with
Suggested Name** takes priority and cancels an early answer still in
progress. As before, everything runs on this Mac.

This does cost processor time each time you copy something. If Diptych seems
to use too much CPU when you copy, untick **Settings ▸ Apple Intelligence ▸
Start naming what is copied before it is pasted**.

---

## Upgrading

Nothing to do. Naming ahead of time is switched on, but it does nothing unless
Apple Intelligence is also switched on in Diptych.

---

*761 tests.*
