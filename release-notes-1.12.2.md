# Diptych 1.12.2

**Rename** on the right-click menu is now a submenu, like Copy: the word itself
renames one file in place, and the arrow opens the rest -- Rename Many, Suggest
Name, four one-click transforms, and a new find-and-replace across names. Rename
Many's replacement gains per-file placeholders: a serial number, dates, owner,
group and EXIF values.

---

## The Rename submenu

Clicking **Rename** still renames the one selected file in place. The arrow now
opens everything else:

- **Lower Case** and **Upper Case** change the whole name's letters.
- **Spaces to Underscores** and **Spaces to Dashes** replace every space in the
  selected names.
- **Replace…** opens a window that finds text A in the selected names and puts B
  in its place -- every occurrence, anywhere in the name, which is *not* the
  whole-name match Rename Many does. Tick **Regular expression** and A is a
  pattern and B its replacement, so `\s+` → `-` collapses each run of spaces to
  one dash across the whole selection. The new names are previewed before
  anything runs.
- **Rename Many…** and **Suggest Name…** are where they were.

Each acts on the whole selection, runs through the same collision-safe planner
as Rename Many -- nothing is touched unless the whole plan is sound -- and is a
single Undo step.

## Placeholders in Rename Many

The replacement understands placeholders filled from each file, so one
replacement gives a different name per file, alongside the regular expression's
own `$1`, `$2`:

- **`$n`** -- a serial number, 1, 2, 3 … in the order the files are listed.
- **`$cdate{YYYY-MM-DD}`** and **`$mdate{YYYY-MM-DD}`** -- the created and
  modified dates, in a format you give; the everyday `YYYY` and `DD` are
  understood.
- **`$owner`** and **`$group`** -- the owning user and group.
- **`$exif{DateTimeOriginal}`** -- an EXIF value of an image, by its name.

A small grey line under Replace lists them, a braces button inserts one, and
**Control-Space** opens the same list in the field. Whatever a placeholder fills
in goes in literally, so a value that happens to contain a `$` can never turn
into a backreference by accident.

## Trashing with administrator rights

**Move to Trash** no longer just fails when you lack permission -- deleting an
application from the Applications folder is the usual case. When the move is
refused for permission, Diptych offers to do it **as administrator**: macOS
shows its own password prompt once, for the whole set, and the items go to the
Trash as root, recorded for Original Location and Undo like any other.

It only offers this where it can actually help: a read- *or* write-permission
refusal on a writable volume. Something on the sealed system volume -- where not
even root may write -- or on a read-only disk is reported as before rather than
asking for a password that would change nothing.

## Upgrading

Nothing to do.

---

*1459 tests.*
