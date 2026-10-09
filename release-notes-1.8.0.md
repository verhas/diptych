# Diptych 1.8.0

Images get an EXIF editor — with a map, pasting places from Google Maps, and
an erase that Undo takes back — the path bar becomes links to the folders above
while Option is held, a circle between Back and Forward lists the folders you
have been in, and what a dialog or an alert says can be selected and copied.

---

## Editing EXIF

**Right-click ▸ Image ▸ Edit EXIF…** on one or more JPEG or HEIC images opens
a window with the images at the top and their EXIF fields below: camera,
artist, copyright, dates, lens, exposure, location and more.

### The window

- **The images are listed with their full paths**, since the window lives on
  its own and can hold images from different folders. Pick one and press
  **Space** for Quick Look, or **Return** or **F3** to open it; a double-click
  opens it too.
- **Save is ⌘S**, not Return, which saved half-finished typing too easily.
  **Escape does not close the window**: Cancel, ⌘W or the close button do.
- **Undo puts the images back** exactly as they were: Save is one *EXIF
  Change* step in Edit ▸ Undo, for all of them.
- **The picture itself is not touched**: only the EXIF is rewritten, not the
  image data. Each image is checked after the change and before it is
  written, and one where a change would not stay is left as it was, with a
  word about which field.

### The fields

- **A field the images disagree on is grey and empty**, and what you type
  there replaces every image's value.
- **Each field has a box**, ticked as soon as you type in it: only ticked
  fields are written on Save. Untick one and it greys out, keeping what you
  typed; click back into it and it is ticked again, the editing carrying on.
- **Fields can be removed from the images**, and **Add Field** shows one they
  do not have yet. Image Width and Height come back from Add Field with each
  image's own size.
- **A description from Apple Intelligence**: for one image without a
  description, Apple Intelligence suggests one in the background, on this Mac.
  It arrives grey and unticked, and is written only if you tick it.

### Help with the values

- **Dates** are typed a part at a time — year, month, day, hour, minute,
  second — and a new number starts only when a part is full or you move to
  another, never after a pause: 2026 typed slowly is still 2026. Delete takes
  back a part's last digit, Up and Down step a part, and a calendar button
  picks the day.
- **Time zones by name** — each image gets the offset its zone had on its own
  date, summer time included.
- **Lists for fields with defined values**, such as Metering Mode or
  Orientation.
- Any of them can be typed instead. **Unusual values are orange** — a date in
  the future or before 1975, a GPS date before GPS time began in January
  1980, a value not on a field's list — and can still be saved. **Impossible
  ones are red**, and Save waits for them.

### Location

- **Latitude and longitude are checked**, and typed in decimal degrees,
  degrees and minutes, or degrees, minutes and seconds; one button in the
  Location heading converts between them. A minus sign or N/S/E/W sets the
  hemisphere, and an **o typed becomes °** as you type it.
- **Paste a place from Google Maps** into Latitude or Longitude — the
  coordinates, the share link, or the plus code — and all four location
  fields are filled.
- **A world map pins the location** when both are there; a click opens it in
  Google Maps.

### Erasing EXIF

- **Right-click ▸ Image ▸ Delete All EXIF Data** takes every EXIF, TIFF and
  GPS field out of the selected images, with the lens and serial number
  Adobe's XMP keeps beside them, without asking: it is one *Delete EXIF* step
  in Undo, and a message says *3 files' EXIF data was erased, undoable*.
  Orientation stays, or the picture would show turned.

### For agents

- **The new MCP tool `open_exif_editor`** opens the editor on images from any
  folders; the editing and saving are yours.

---

## The path bar

- **Hold Option** over the path bar, or while typing in it, and the path
  becomes links, one per folder: **/ Users / verhasp / github**. Click one to
  go there -- several levels up in one click, with the folder you came out of
  selected, as going up does. Let Option go and the text is back, with what
  you had typed and selected.
- **The circle between Back and Forward** lists the folders the pane has been
  in, most recent first, each once. Unlike Back and Forward it keeps a folder
  you went back from and then left for somewhere else. Folders that are gone
  are left out, and the list is saved with the pane, so it survives a restart.

---

## Windows

- **Every Diptych window stays in the Dock's window list and in Option-Tab's
  rotation** — the EXIF editor among them — also when it was closed and then
  opened again for the same files.

---

## Copying text

- **Everything a dialog says can be selected and copied**: the tips, the
  questions before moving to the Trash or running a script, notices, and the
  rest. Clicking a checkbox or an option still ticks it.
- **Alerts too** -- the ones about unsaved changes, updates, files changed on
  disk, and the others: their title and message can be selected.

---

## Upgrading

Nothing to do.

---

*912 tests.*
