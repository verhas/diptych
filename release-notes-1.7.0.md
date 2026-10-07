# Diptych 1.7.0

A symbolic link shows how far it goes and where it ends, a file with several
names says how many it has and can find the others, and a script runs in the
Runs window, where it can take as long as it likes.

---

## Symbolic links

- **A link is followed to its end**, through every link it leads to, and the
  arrow after its name says how that went:
  - **(2)**, in plain text, for a link that reaches a file or folder through
    two links. A link straight to its target shows no number.
  - **A red dot** when the end is not there, with the number of links before
    it: **(2)** for a link to a link to nothing. A bare dot is a link whose
    own target is missing.
  - **A red broken circle with an arrow** when the links go round in a loop,
    with how many can be followed before one comes round again —
    x5 → x4 → x3 → x2 → x1 → x3 shows **(4)**. A link to itself shows the
    bare circle.
- **Hover the arrow** to see what the link points to — the next step, as
  stored, whether or not anything is there.
- **Double-click the arrow** to go to the link's target. A double-click
  anywhere else on the row opens it, as before.
- **Go to Final Target**, under Go to Link Target, goes past every link to
  the file or folder at the end. It is offered for a link to a link that ends
  somewhere real, not for a loop.
- **Go to Link Target** is offered whenever the link's own target is there —
  also when that target is a link that leads nowhere.
- **Quick Look on a link shows the link**, not its target: that it is one,
  every step it goes through, and how it ends — the file with its size and
  date, the name that is not there, or where the links go round.

---

## Hard links

- **A file with more than one name says so.** Several hard links to the same
  file — the same inode — show the number of names, in grey, after the name:
  **(2)**.
- **Right-click ▸ Find Sibling Names (Hard Links to the Same File)…** opens a
  window that searches for the other names. It reads outwards from the file —
  its own folder and everything below it, then the folder above, and so on
  up to the top of the disk — and stops as soon as it has them all. Names
  made near each other are found at once; a search of a whole startup disk
  takes about two minutes, where `find / -inum` takes three and a half.
  Double-click a name to see it in a pane.
- **Each hard link keeps its own name.** The second name of a file was listed
  under the first — the pane showed two rows called "x5" and none called
  "hardx5". Compare Folders paired such a file with the wrong one on the other
  side for the same reason.

---

## Scripts

- **A script runs in the Runs window**, in a tab of its own, rather than in a
  box over the panes — so the panes stay usable while it runs, however long
  that is. Its tab has Stop, Copy Output and the timing, and the run is kept
  in the log like any other. The script still receives its items exactly as
  before, with no shell in between, from the copy you approved. To run it
  again, use the Scripts menu, which checks it afresh.
- **A script that cannot be read is reported when Diptych starts.** It used to
  be left out of the Scripts menu without a word. The list says what is wrong
  with each, line by line.
- **Developer mode says where its command is**: it adds the menu item
  "File ▸ Read the Scripts Folder Again".

---

## Windows

- **The Runs window is in the Dock's window list and in Option-Tab's
  rotation**, also after it has been closed and opened again for another run.

---

## Upgrading

Nothing to do.

---

*823 tests.*
