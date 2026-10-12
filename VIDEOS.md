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

## 2. Comparing directories -- idea

- Compare Folders between the two panes: what is the same, what is
  different, and what exists only on one side.
- How renamed files are recognised.
- Drilling into one pair of files to see the text differences.
- Copying a difference across, and undoing it.

## 3. Flat view and the selection expression -- idea

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
