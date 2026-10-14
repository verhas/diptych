# Diptych 1.10.0

Compare Folders can now sync two folders: both ways, each change going the
way it was made, or one way, making one folder the same as the other. Find
Duplicates finds the copies of a file, or every set of copies in a folder.
Paste Special makes one property of a copied file -- its permissions, dates,
owner, attributes, EXIF -- the same on the selected ones. Comparing two files
now also says what differs besides their contents, side by side. And Settings
decide what a copy keeps: its dates, permissions, group, extended attributes
and access control list.

---

## Sync in Compare Folders

- **Sync ▸ Sync Both Ways…** is for two folders where neither is the master.
  Diptych keeps a record of each sync in `~/.diptych/sync`, so next time it
  knows what changed on which side: an edit, a new file, a deletion or a
  rename is carried to the other side.
- **Conflicts are yours to decide.** A file changed on both sides, or deleted
  on one and changed on the other, waits for a choice: either way; keep both,
  so that each side has both files, the older one renamed; or leave as is,
  and be asked again next time. Newer Wins, Keep Both and Leave as Is decide
  them all at once. Every other row can be changed too. A click on the name
  of two files opens them side by side; on two folders or links, their
  properties.
- **The first sync** copies whatever is on one side only to the other, since
  without a record nothing can be told to be a deletion.
- **Sync ▸ Make Right Same as Left**, or the other way: the target ends up as
  deleting it and copying the source over it would -- content, permissions,
  extended attributes, ACLs and dates -- but only what differs is touched.
  Missing items are copied, extra ones deleted, changed files replaced, and a
  file that differs only in its permissions, attributes or dates gets just
  those set. A file the comparison matched by content under another name is
  renamed, not copied again.
- **You see the plan first.** The folders are compared afresh, and every
  change is listed before anything is made.
- **Nothing is lost by accident.** Deleted items, and the old versions of
  replaced files, go to the Trash; *Delete outright* is there for a server
  without one. A replacement is copied beside the old file and takes its name
  only once it is complete.
- **It goes as far as the comparison looks.** What is not ticked -- the dates,
  say -- is not compared, so it is not a reason to change anything.

## Properties side by side

- **The file comparison says what differs besides the text.** Under the two
  names, one line names whatever else differs -- permissions, owner, group,
  flags, dates, the ACL, each extended attribute -- and opens to the values
  side by side. It opens by itself when the text is the same, which is when
  a folder comparison or a sync called two files different for another
  reason. Dates are shown to the nanosecond when they share a second.
- **Same text, other bytes** -- line endings, a byte-order mark, an
  encoding -- is said, rather than "the same".
- **Two files that are not text** get the same properties under the verdict.
- **Compare Folders ▸ Properties** (⇧⌘I) shows the same for the selected
  pair, folders and links included.

## Find Duplicates

- **File ▸ Find Duplicates…**, right-click, or a toolbar button you can switch
  on in Settings ▸ Toolbar -- for one selected file or folder.
- **For a file**: the files holding the same bytes, nearest first -- its
  folder, the folders under it, and, ticked, the rest of the volume going up a
  folder at a time, then the other volumes.
- **For a folder**: the files in it holding the same bytes, in groups.
- **Listed as they are found**, with the pane's icons for links, broken and
  looping links, hard links and executables, and the Compare Folders letters
  for what else differs: dates, permissions, attributes, ACL, owner.
- **Select and move to the Trash** -- never every file of a group; when that
  is what keeps the button greyed, the window says so. A click on a path shows
  the file in the browser.
- **Links** -- hard and symbolic -- are listed as duplicates only when asked.
  A symbolic link is followed, and listed with the file it leads to, wherever
  that is.
- **Stop** works while the search runs, and closing the window stops it.
- **Each other volume has its own checkbox**: the backup disk, not the video
  server.
- **How wide it has gone** is shown above the progress: its own folder, the
  subfolders, then everything under one folder further up each time, then the
  other volumes -- to stop it once it is wide enough.
- **A link that would lead nowhere** once the selected files are in the Trash
  is named, in purple, without stopping the move; a click shows every such
  link and where it leads.

## Paste Special

- **Edit ▸ Paste Special**, or a right-click: copy one file, select others, and
  paste its **Permissions**, **Extended Attributes**, **Access Control List**,
  **Modified Date**, **Created Date**, **Owner**, **Group**, **Location** or
  **EXIF** onto them -- or **All of the Above**.
- **Location and EXIF** are offered only when the copied file has them and
  every selected file is a JPEG or HEIC picture; All of the Above copies the
  EXIF where it can and everything else everywhere. Which way up a picture is,
  and its size, are never copied.
- **One step in Undo**, whatever it took in.
- **Dates to the nanosecond.** The pasted dates are exact, and Undo puts the
  old ones back just as exactly.

## What a copy keeps

- **Settings ▸ Behaviour ▸ Copying** decides it, for every copy: from the
  panes, by dragging, or by an agent. The created and the modified date can
  each be the original's or the time of the copy. Permissions can be the
  original's, a new file's (0666 less the umask), or set separately for files
  and for folders with the permission grid of the panes, setuid, setgid and
  sticky included. The group can be the original's, or the target folder's
  when that folder has the setgid bit. Extended attributes and the access
  control list can each be kept or left out.
- **Everything is kept out of the box**, as before. A move and a sync always
  keep everything.
- **A downloaded file stays quarantined** even when extended attributes are
  left out.
- **EXIF and location** are part of the file's contents and always copied; the
  settings say so.
- **Agents** can set all of it with `set_setting`.

## Fixes

- **A copy keeps its created date.** Copying from the panes gave the copy the
  modified date, or the time of the copy, as its created date. It now keeps
  the original's, to the nanosecond, for every file in a copied folder too.
  An agent's copy of a folder kept its files' dates but gave the folder itself
  the wrong created date; it keeps it now too.

---

## Upgrading

Nothing to do. Copies keep everything, as before, until Settings ▸ Behaviour ▸
Copying says otherwise.

---

*1281 tests.*
