# Diptych videos

A working list of short feature videos, about three minutes each, in the
style of the intro: a test folder, a 1920×1080 window, keystrokes and clicks
on camera, a title card per section, and a closing card.

Status: **done**, **next**, or **idea**.

## 1. Intro -- done

- Video: <https://youtu.be/MhCf82QWO7o>
- File: `~/Movies/Diptych-intro.mp4`. 3:05 long, 1080p at 30 fps.
- Music: "Wallpaper" by Kevin MacLeod (incompetech.com), licensed under
  CC BY 4.0. The attribution is in the YouTube description.
- Content: two panes, the keyboard, Quick Look, Text Edit, the agent and its
  review window, and undo.

## 2. Comparing directories -- done

- File: `~/Movies/Diptych-02-comparing-directories.mp4`. 1:50 long, 1080p at
  30 fps, music "Wallpaper" by Kevin MacLeod (CC BY 4.0), as the intro.
- Demo folders: `test_folder/make-12-compare.sh`.

- Compare Folders between the two panes: what is the same, what is
  different, and what exists only on one side.
- How renamed files are recognised.
- Drilling into one pair of files to see the text differences.
- A pair that differs only in permissions or a tag: the comparison window
  opens the properties side by side by itself.
- Copying a difference across, and undoing it.
- Compare Folders ▸ Properties (⇧⌘I) on a pair of folders or links.
- Syncing has its own video (23), and so has Find Duplicates (24).

## 3. Flat view and the selection expression -- done

- File: `~/Movies/Diptych-03-flat-view.mp4`. 1:53 long, 1080p at 30 fps,
  music "Wallpaper" by Kevin MacLeod (CC BY 4.0).
- Demo tree: `test_folder/make-13-flat.sh`. Handing the selection to the agent
  is left to video 9.

- A whole folder tree shown as one list.
- Selecting files with an expression: by name, size, date and type.
- Acting on the selection: copy, move, archive, hand it to the agent.

## 4. Editing structured files -- idea

- XML, YAML, JSON and plist files in Text Edit.
- The tree view, and editing a value in place.
- Completion, closing tags, structure emphasis and format checks.
- Folding, and Go to Line (⌘G).
- Opening a binary plist and saving it back as binary.

## 5. Soft links and hard links -- idea

- The small icons and counts next to linked files, and what each one means.
- Hovering the arrow to see where a link points; a link followed to its end.
- Go to Link Target and Go to Final Target.
- A broken link, and what its right-click menu offers.
- Hard links: Find Sibling Names, the other names of the same file.
- The Quick Look page for a link, which shows the link rather than its target.

**Editing note:** the link icons and counts are only a few pixels in a
1080p frame and can't be read at normal size. Zoom in on them slowly, Ken
Burns style, while the narration explains them: the arrow, the hard-link
count, the red dot of a broken link and the orange executable badge. Hold
long enough to read each one, then zoom back out to the whole window. Do
the same for the arrow when hovering over it.

## 6. EXIF and maps -- idea

- The EXIF editor and the map of where a photo was taken.
- Clicking the map to open the place in Google Maps.
- Copying a location in Google Maps and pasting it into the EXIF editor.
- Fixing a wrong date or camera, and undoing it.

## 7. Running executables -- idea

Related to scripts (chapter 8), but not the same thing: any program or
script, run from its right-click **Run ▸** menu with arguments you type.

- Run with Arguments… (⌥↩): the arguments on one line, ↑ and ↓ for earlier
  ones, and the exact command shown before it runs.
- Environment variables for that program, set after the login shell starts,
  so a `.zprofile` cannot override them.
- Saving a set of arguments and variables as a template.
- Running it again from the history in the menu: Ⓣ marks a template, Ⓔ a
  run that set variables.
- The Runs window: one tab per run, a real terminal, Stop, Run Again, Copy
  Output, and the exit code and timing.
- A downloaded script is asked about before it runs.
- The history follows the program when it is moved.
- An agent cannot run anything, but it can read a run's output to explain a
  failure.

## 8. Scripts of your own -- idea

- Turning on the scripts in `~/.diptych/scripts`, in Settings ▸ Behaviour.
- File ▸ Get Scripts…: picking from the scripts that come with Diptych,
  reading one's source, and installing.
- A script's header lines: name, description, apply-to, args, only-in,
  only-under and call.
- `apply-to` as a flat view expression: `file and name = "*.jpg"`, and
  `path != "*/.git/*"` to keep a script away from a repository's insides.
- The script appearing under File ▸ Scripts and Right-click ▸ Scripts, only
  for selections it suits.
- The question before the first run, and the safety rules: nothing
  downloaded, nothing anyone can write to, nothing others can read.
- A mistake in a header reported at startup.
- A script that takes no items, offered on the empty space below the rows.
- Developer mode, and Read the Scripts Folder Again.

## 9. The AI agent in depth -- idea

- What the agent can see and do through MCP.
- The review window: unticking rows and editing a target name before
  anything happens.
- Undoing a whole batch at once, with Undo/Redo Many (⌃⌘Z).
- Tags, extended attributes and quarantine through the agent.

## 10. Rename Many -- idea

- One regular expression over a whole folder (⌃⌘R), always matching the
  whole name, with `$1`, `$2`… in the replacement.
- Each file shown with the name it would get; non-matching files dimmed.
- Selection only, and Rename Many on a flat view, across folders.
- The plan is checked before anything is renamed: clashes are refused, naming
  both files.
- **Renames that depend on each other are put in order.** `(.)(..)` → `$2$1`
  on `ABC`, `BCA` and `CAB` turns each into the next, though every new name is
  one of the old ones. A chain runs in the order that frees each name before
  it is needed. A loop like this one has no such order, so one file steps
  aside under a temporary `.diptych-rename-…` name and takes its new name at
  the end. The window says when that happens.
- Undoing the whole rename in one step.
- Renaming photos by their EXIF date is a job for the agent, not this window.

## 11. Apple Intelligence -- idea

- Rename with Suggested Name.
- A description for an image, written into its EXIF.
- Everything runs on the Mac; nothing leaves it.

## 12. Quick Look as a workbench -- idea

- Stepping through files with the preview open.
- Renaming with F2 while the preview stays in front, even with the window
  half covered.
- The tailored previews: Markdown, plist structure, `.DS_Store`, folder
  listings, archive contents, and the link chain.

## 13. Bin Edit -- idea

- The hex editor: moving around, editing, and searching.
- Comparing two binary files.

## 14. Git in the panes -- idea

- Version tracking in Settings, using the Mac's own `git`.
- Name colours that answer one question: what happens to this file when I
  send my work?
- Sending and getting, and sending only part of your work.
- Check for Changes (⇧⌘K): what others have sent, and red names for files
  both of you changed.
- Track This File, Never Track This, and Stop Tracking This File.

## 15. The agent terminal -- idea

- View ▸ Show Agent Terminal (⌃`): the agent already running and already
  connected to Diptych.
- Talking about the files you are looking at in plain language.
- Resizing the panel and copying from it.

## 16. File info, permissions and attributes -- idea

- Editing permissions with F4.
- Changing the owner and the group.
- Extended attributes, quarantine, and where a file was downloaded from.
- What a copy keeps: copy a tagged file with the default settings and show the
  dates, tags and permissions in Properties side by side; switch Settings ▸
  Behaviour ▸ Copying to the time of the copy, no attributes, `rw-r-----` in the
  file grid and the group of a setgid folder,
  copy again and compare. A downloaded file stays quarantined either way.
- Paste Special: copy one photo, select a dozen others, paste its Location;
  then All of the Above onto a mixed selection, and Undo as one step. The
  dates match to the nanosecond in Properties side by side.
- Directory sizes.

## 17. Making the panes your own -- idea

- Arranging columns.
- Putting files in your own order.
- Font size and zoom.
- Favourites in the sidebar, and spring-loaded folders when dragging.

## 18. The Image menu -- idea

Right-click ▸ Image ▸ on one or more pictures.

- Edit EXIF…, Delete All EXIF Data, and Remove Location before sharing a
  picture.
- Rotate and flip: a JPEG or HEIC is turned by its orientation tag, so no
  quality is lost, and an open Quick Look turns with it.
- Convert… to JPEG, HEIC, PNG or TIFF, and Resize… to a longest side. Both
  make new files next to the originals.
- Remove Background: the subject cut out with Vision, on this Mac.
- Recognize Text…: into a `.txt` beside each picture, which the flat view's
  `contains` then finds, or into its Spotlight comment.
- Make PDF…: a multi-page TIFF of old scans into one PDF, and a dozen
  photos into one PDF on A4 pages, a sideways one turned upright.
- Set as Desktop Picture.
- Undo for all of it.

## 19. The Video menu -- idea

Right-click ▸ Video ▸ Edit Metadata… on QuickTime and MP4 videos.

- The same editor as for pictures, with a video's fields: title,
  description, artist, date taken with its time zone, camera, and location
  with the map.
- Pasting a place from Google Maps, as for photos.
- Several videos at once, and Copy and Paste as JSON.
- Nothing is encoded again, and Undo puts each video back as it was.

## 20. Right-click menus you may have missed -- idea

- The empty space below the rows: New Folder, New File, New from Clipboard,
  folder scripts, Paste, Paste as Link, Rename Many…, Select All, Refresh.
- Go to Link Target and Go to Final Target on a link.
- Find Sibling Names on a file with hard links, and Show in Diptych in its
  window.
- The EXIF editor's file list: Open, Quick Look, Copy Path.
- The column headers: showing, hiding and ordering columns.
- Diptych ▸ Check for Updates…, and the update setting.

## 21. Directory sizes -- idea, about 2 minutes

View ▸ Calculate Directory Sizes, or **∑** in the toolbar.

- Every folder in the pane gets its total in the Size column, everything
  under it counted. The command is greyed out while the Size column is hidden.
- The colours: teal for a finished total, orange for one still changing, and
  `??` for a folder nothing is known about yet.
- Early estimates that grow as the folders inside are read, with the totals of
  the folders above following.
- Sorting by Size while it runs: the rows move as the totals grow.
- It keeps going in the background while the pane goes elsewhere. One reader
  per volume, so a second request waits its turn.
- The Info window shows the same total.
- View ▸ Clear Directory Sizes.

## 22. File servers -- idea

Go ▸ Connect to Server… (⌘K), with a NAS on the network.

- Typing `nas/photos`, and the system's own password window with *Remember in
  Keychain*.
- The server found on the network, and a double-click instead of typing.
- Starring it: it appears in the sidebar under Servers. Connect When Diptych
  Starts.
- Copying from the server to the Mac with the other pane, one keystroke.
- A change made on another computer appearing within seconds.
- Quitting Diptych, disconnecting the server, starting again: the pane brings
  the server back and opens the same folder.
- An FTP server: read-only, and the menu items greyed out; a file opened in
  Text Edit there says the volume is read-only.
- Going back into a big folder: its rows at once, "as listed at …, reading it
  again" in the status line, then the fresh listing.
- The sidebar's free space for the server, and the refresh interval in
  Settings set to 0.

## 23. Syncing two folders -- idea

Compare Folders ▸ Sync, with a photo folder and its copy on a USB disk.

- **One way:** Sync ▸ Make Right Same as Left. The folders compared afresh and
  the plan listed before anything happens: copied, deleted, replaced, and a
  file that differs only in its permissions or dates getting just those set.
- A file renamed on the left is renamed on the right, not copied again.
- After the sync: the deleted files and the old versions of the replaced ones
  are in the Trash. A sync goes only as far as the comparison looks: untick
  the dates, and dates alone are no reason to change anything.
- **Both ways:** Sync ▸ Sync Both Ways… on a folder kept on two Macs. The first
  sync copies whatever is on one side only to the other.
- Then edit a file on the left, delete one on the right, rename a third, and
  sync again: each change goes the way it was made, because the last sync was
  recorded in `~/.diptych/sync`.
- A conflict: the same file edited on both sides. A click on its name opens the
  two side by side; decide it with Keep Both, and each side has both files,
  the older one renamed. Newer Wins and Leave as Is for the rest at once.
- A server without a Trash: *Delete outright*.

## 24. Finding duplicates -- idea

File ▸ Find Duplicates…, right-click, or the toolbar button switched on in
Settings ▸ Toolbar.

- **A folder:** a photo folder with years of imports. The groups appear as
  they are found, each with the Compare Folders letters for what else differs
  -- dates, permissions, attributes.
- Selecting all but one in each group, Move Selected to Trash, and Undo. Select
  every copy of a group and the button greys, with the reason in orange.
- **One file:** one photo, looked for nearest first -- its folder, the
  subfolders, then a folder further up each time. The stage line above the
  progress says how wide it has gone; Stop once it is wide enough.
- The other volumes, each with its own checkbox: the USB backup ticked, the
  video server not.
- Links: a symbolic link listed with the file it leads to, even outside the
  folder. Trashing that file shows a purple warning, and a click lists every
  link that would lead nowhere.
- A click on a path shows the file in the browser.

## 25. Archives -- idea

Archive ▸ Create Archive…, with a folder of photos and a script.

- The window: everything selected listed, ZIP chosen. Create, and the zip
  appears selected; open it in Quick Look to show `__MACOSX` is not among the
  files but the tags came back.
- Untick the Mac data, make it again, and show the zip on a Windows share
  without the clutter.
- tar.gz with the owners as root and wheel; Apple Archive with LZMA.
- Several items from a flat view in one archive; two of the same name refused.
- Extract Here on a zip holding a setuid program: the question, with what the
  archive records. Extract Without Them, then Undo, then Restore as
  Administrator… and the password; `ls -l` in the agent terminal shows the bit.
- A downloaded archive: what comes out is quarantined too.
- Return on a zip: the bar, then the zip as a folder, the path bar reading
  `…/photos.zip/2024`. Quick Look a photo inside, copy one out to the other
  pane, try to rename one -- greyed. Up lands on the zip.
- A zip under AES-256 and one under ZipCrypto, with the warning; an `.aea`
  with a long password. Return on each: the password asked, a wrong one asked
  again.
- A Disk Image of the same folder, encrypted: Return mounts it after the
  password, the pane on its volume, ejected from the sidebar. An ISO for a
  virtual machine.
- Drag the `.dmg` onto the sidebar: it becomes a favourite. Click it later --
  it mounts and the pane goes to its volume.

## 27. Recovering a ZIP password -- idea

Archive ▸ Recover ZIP Password…, on a zip whose password was mistyped by one
letter -- the legal note in orange at the top throughout.

- Return on the zip, type the password a letter wrong: refused, with the line
  that there is no limit and no lock-out. The Recover Password… button has
  appeared -- press it, and the recovery window opens on the same zip.
- "From a password I remember": type it a letter wrong, Search. It tries the
  guess, then keys nearby, and lands on the real password in a moment; Copy.
- Switch to "Try every combination": pick letters and digits, set the length,
  and watch the estimate -- short is seconds, a step longer turns orange and
  says "not in your lifetime".
- A short brute force actually run, the bar and the rate climbing, Stop.
- Scroll to the note pointing at hashcat and John the Ripper for the GPU.

## 26. Making files smaller -- idea

File ▸ Optimize File Size…, on a folder of phone photos, screenshots and a
scanned PDF, all selected at once.

- The window: every file with the size it would have; the settings of each
  kind, one group each.
- Drag the photo quality down and watch the sizes change; drag across the
  picture to move the line between before and after, then zoom to 100 %.
- A screenshot at 256 colours, then 32 with and without dithering; a
  transparent PNG keeping its colours.
- The scanned PDF at 150 and at 72 pixels per inch, page by page.
- A file that would not get smaller, unticked in orange.
- Optimize, Get Info on one: the same file, same date; Undo puts them all
  back.

## 28. Previous versions of a file -- idea

File ▸ Previous Versions…, on a document edited a few times over a day that
Time Machine has been keeping hourly local snapshots of.

- The window lists the earlier versions newest first -- the time of each, a
  local snapshot or Time Machine, the size.
- Pick one, Compare: the comparison window opens, the old version on the left
  and the file as it is now on the right, the changed lines marked. Close it;
  the versions list is still there.
- Pick an older one, Compare again -- a different window. Decide this is the
  one.
- Restore: the alert naming the moment it goes back to; confirm. The file now
  holds the old contents but is the same file -- Get Info shows its name and
  permissions unchanged. Undo puts it back.
- A word on the quiet part: no password, nothing mounted by hand -- it reads
  the snapshots macOS already keeps, and says so when Full Disk Access is what
  it is missing.


## 29. Splitting and joining a file -- idea

A big file -- a disk image, a video -- that will not fit where it has to go.

- Right-click ▸ Split File…: the dialog, the size field, the ready-made sizes
  (Email, CD, DVD, FAT32). Pick one, Split. The parts appear beside it --
  `.001`, `.002`, `.003` -- each the size asked for.
- Move the parts somewhere and back, or just show them on their own.
- Select the first part, Join Parts: the file is back, and a quick Compare or a
  checksum shows it is the same bytes. The original that was still there was not
  touched -- the join made `name (2)` instead.
- Undo removes what either step made.

## 30. More in the Info window -- idea

Three tabs added to Get Info (⌘I), each read when first shown.

- Signature: on a notarized app, the green seal and "Signed and notarized by
  Apple", the team, the certificate chain, Gatekeeper accepted, ticket stapled.
  On a plain download, "not code-signed". Check Again re-runs the tools.
- Open Using: the apps that can open the file, the default marked. Open in one
  without changing anything; Set as Default, and the note that it changes every
  file of the kind.
- Share: the file's icon and kind, and the native Share button -- the same
  sheet as Finder, Mail and AirDrop and the rest.
