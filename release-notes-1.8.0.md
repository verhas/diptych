# Diptych 1.8.0

A pane can show a folder and everything under it as one list, filtered by an
expression much like `find`'s -- which also asks pictures and videos when,
where and with what they were taken; images get an EXIF editor — with a map, pasting
places from Google Maps, and an erase that Undo takes back — and any picture
can be turned without loss, converted, resized, cut out of its background or
have its text read; Text Edit gets a gutter that shows what changed since the
last commit and since the last save, folds JSON, XML, TOML and YAML, and says
where such a file breaks; Rename Many works on the selection and on a flat
view; the path bar becomes links to the folders
above while Option is held, a circle between Back and Forward lists the folders
you have been in, and what a dialog or an alert says can be selected and
copied.

---

## Flat view

**View ▸ Flat View** (`⇧⌘F`), or the new button after `‹ ○ ›`, turns a pane
into one list of its folder **and everything under it**. Each row has its
folder in front of its name, in grey -- `src/app/View.swift` -- and sorting by
name keeps a folder's files together. The button is lit while the pane is flat;
press it again to go back.

### The expression

The filter gives way to one expression field and a ▶ button (or Return):

```
directory traversed, file and name ~ /\.(jpe?g|png|heic)$/i and size > 1MB
(directory and name = "src") or (file and name = "*.swift")
modified >= 2026-01-01 and access = "***r**r**" and not xattr("com.apple.quarantine")
```

- **Tests:** `name = "*.txt"` (a shell pattern) and `name ~ /regex/`; `size`
  with `KB`, `KiB`, `MB`, … ; `created` and `modified` in ISO 8601, to the
  precision written; `access = "rw*r**r**"`, with `*` for either; `owner`,
  `group`; `xattr("name")` and its value; `contains "text"` and `contains ~
  /regex/`, never in a binary file; `file`; `directory`, `directory traversed`
  (walked into, not listed) and `directory listed` (listed, not walked into);
  `true` and `false`.
- **AND, OR -- or a comma -- NOT and parentheses.** Keywords and quoted values
  ignore case. **Regular expressions are between slashes**, `/…/`, and mind
  case unless `i` follows; a backslash in quotes is just a backslash.
  **`/* … */` is a comment.**
- **An expression without `file` or `directory` is about files**: every folder
  is listed and walked into. With either, folders are asked too -- so
  `directory traversed, file and …` searches the whole tree and lists files.

### Typing it

- **Errors are underlined in red** as you type, with the reason under the
  field; the line says what the word at the caret takes otherwise.
- **What cannot be meant is underlined in orange**, and can still be run: an
  expression that lists nothing, one that walks into no folder, and an AND that
  can never hold -- a file that is a folder, one permission bit both set and
  clear, sizes or dates that do not meet, two exact names, a name another test
  rules out, a test and its opposite. A run that finds nothing says so.
- **Control-Space** offers what can come next; when only one thing can, it is
  inserted at once. After `access =` it offers `"*********"`, and inside those
  quotes typing overwrites, as in the pane's permission editor.
- **Control-Space where a date goes** -- after a date test and a
  comparison, or on a date already written -- opens a calendar instead, with
  the time when it is ticked.
- **A long expression gets every line it needs** while it is being edited.
- **The right-click menu is the expression's own**, from the first click:
  Expand, Save Expression, and Cut, Copy, Paste, Select All -- no calendar
  events, Services, AutoFill or Writing Tools in an expression.

### Pictures and videos

The expression can ask what a picture or a video says about itself, read from
its header -- never its pixels -- so a file is known by its bytes, not its name.

- **What it is:** `image` (raw files and SVG drawings too), `video`, `exif`,
  `located`, `flash`, `landscape`, `portrait`, `square`, `rotated`,
  `transparent`, `animated`, and `format = "heic"` -- the formats are listed
  in the README; `"raw"` is any camera's raw.
- **What it says:** `camera = "*iPhone*"`, `lens`, `software`, `artist`,
  `copyright`, `description`; `taken` and `digitized` dates; `iso`, `aperture`
  (`2.8` or `f/2.8`), `shutter` (`1/250`, `2s`), `focal` and `focal35`,
  `width`, `height`, `megapixels`, `altitude`, `rating`, a video's `duration`.
- **Where:** `near(47.4979, 19.0402, 5km)`, and `city`, `state` and `country`
  -- as written in the file, or else the nearest town of 15,000 people or more
  within 50 km, from a GeoNames list in the app: looked up on this Mac, never
  asked of a service. The list is `~/.diptych/exif/places.json`, to correct:
  a town can be disabled, or fixed and marked `manual`, which a later version
  then leaves alone.
- **Videos** -- MOV, MP4, M4V, 3GP -- say when and where they were taken, the
  camera, their size and their length.
- **Metric and imperial**: `5km` or `3mi`, `2000m` or `6000ft`, `50mm` or `2in`.
- **What a file does not say makes its test false**, with `!=` too: a text
  file is not `camera != "x"`. Only NOT makes it true, so `not located` lists
  every text file as well -- the line under the field says so, and `image and
  not located` keeps to pictures.
- **New warnings**: a picture and a video at once, landscape and portrait, two
  formats, numbers or dates in ranges that do not meet.
- **Control-Space** offers the usual ISO values, f-stops, shutter speeds and
  focal lengths, the units after a number, the formats, and -- after `camera
  =`, `lens =` and the like -- what the flat view found, commonest first. A
  calendar after `taken` and `digitized` too.
- **The cheap tests first**: `name = "*.heic" and iso > 1600` opens only the
  HEIC files.

### Dates and ranges

- **A year or a month is a date**, for every date test: `modified = 2026` is
  the whole year, `taken = 2024-07` July.
- **`between`** for anything that has an order: `iso between [100, 800)`,
  `taken between [2024-06, 2024-08]`, `size between (1MB, 10MB]` -- a square
  bracket takes the end in, a round one leaves it out.

### Saved expressions

- **Right-click ▸ Save Expression** while editing: a new name, or one already
  used, to replace. Only an expression that parses can be saved.
- **A saved name can be the expression, or part of one**, and stands for its
  expression in parentheses: `images and size > 1MB`. Control-Space offers
  the names. Select one and **right-click ▸ Expand** to replace it with its
  expression, to edit.
- **Each is a JSON file in `~/.diptych/filters`**, holding every older version
  too, newest first -- edit the file to put one back. Replacing one is
  undoable.
- **If one that others use goes**, Diptych says at once which stop working,
  and an expression using them says which name is missing, and through which.
- **A file whose name is not allowed is ignored, and said so**, as Diptych
  starts or when one turns up: the name, why, and the file's full path.

### Walking, and holding still

- **The rows arrive as they are found**, with how many so far and the folder
  being read; **Stop** keeps what was found. Each pane remembers its last six
  walks, so Back to a flat view is immediate.
- **It holds still.** Only ▶ walks the tree again. A row renamed, or its
  permissions set, changes in place and stays, even when it no longer passes
  the expression -- which then turns **brown**, stale, until it is run again.
  A renamed folder takes its rows along. Refresh re-reads the rows and drops
  only what is gone.
- **Opening a folder from it leaves it**, and so do the path bar and the recent
  folders; with Option held, the path bar's last folder is a link back to the
  folder too. A flat pane is saved as flat.
- **A source, not a target**: rows can be copied, moved, renamed and trashed;
  nothing can be copied, moved, pasted or made *into* a flat view. F5 and F6
  on the function bar are greyed while the other pane is flat, F7 while this
  one is.

---

## Rename Many

- **Only the selection, unless told otherwise**: with files selected in the
  pane, **Selection only** is ticked and only they are matched and renamed --
  the other names still count as taken. Untick it for the whole folder.
- **From a flat view** it works on the rows the pane lists -- stale or not --
  renaming each in its own folder, a folder after what is in it. A clash is
  looked for among every name in each folder, and said with its folder. The
  whole rename is still one Undo step.

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
- **Copy and Paste as JSON**: every field with a value to the clipboard, and
  fields from JSON there typed into the window -- to keep an edit that cannot
  be saved, or to give one picture's values to another.
- **A save that fails keeps what was typed**, and says which field by name.
- **Comment takes no accented letters** -- macOS garbles them there -- and
  says so before Save; Description keeps them.
- **Control-Space in Camera Make, Camera Model, Lens Make and Lens Model**
  offers the usual values, spelt as cameras write them (`NIKON CORPORATION`,
  `ILCE-7M4`), narrowed by what is typed; a model's list follows the make.

### Lists to correct, in ~/.diptych/exif

- **`cameras.json`, `lenses.json` and `places.json`** are written on the
  first start, one item to a line, and read on every start.
- **`"disabled": true` takes an item out of use** for good: a new version
  merges its own lists in, keeping what you added and never enabling what
  you disabled.
- **A town, region or country takes a new version's corrections** unless
  you set its `"manual"` to `true`.
- **A file that is not valid JSON is left alone**, Diptych says where it is
  wrong, and uses its own list meanwhile.
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
- **The new MCP tool `show_flat_view`** puts a pane into a flat view with an
  expression -- "list every image under here that the group can read" -- and
  returns at once with the expression's warnings; `get_pane` says while the walk
  is still collecting, and lists the rows. The agent's `AGENTS.md` describes the
  expression language, with examples.

---

## Pictures

**Right-click ▸ Image** is now there for any picture macOS reads -- PNG, TIFF,
GIF and the rest -- with the EXIF items for JPEG and HEIC only. Each of these
is one step of Undo:

- **Remove Location** takes out where the pictures were taken: every GPS field,
  and the city, state, country and location names photo software keeps beside
  them. Nothing else is touched.
- **Rotate Left, Rotate Right, Flip Horizontally, Flip Vertically.** A JPEG or
  HEIC is turned by its orientation alone, never decoded or compressed again,
  so nothing of the quality is lost; any other picture by its pixels, which PNG
  and TIFF keep exactly. An animated picture is left as it is.
- **Convert… and Resize…**, one dialog: JPEG, HEIC, PNG or TIFF, a quality,
  a longest side, the metadata kept or not, the new images next to the
  originals or in the other pane's folder -- `IMG_1.heic` becomes `IMG_1.jpg`,
  resized `IMG_1 (2048).jpg`. Turned upright on the way, never made larger,
  transparency on white for JPEG.
- **Remove Background** finds the subject with Vision, on this Mac, and saves
  it on a transparent background as `IMG_1 (cut out).png`. A landscape or a
  texture with no subject says so and makes nothing.
- **Recognize Text…** reads the text in the pictures with Vision, and asks
  where to keep it: in a text file beside each, `IMG_1.jpg.txt`, which
  Spotlight, `grep` and the flat view's `contains` find; or as the picture's
  Spotlight comment attribute, which the flat view's `xattr` finds -- offering
  to unlock a read-only picture for the moment of the change.
- **Set as Desktop Picture**, for one, on every screen.

The originals are never changed by Convert, Resize, Remove Background or
Recognize Text: they make new files, which Undo moves to the Trash.

- **Quick Look stays on what you are looking at**: changing a picture no
  longer takes the panel to what the other pane has selected, and a picture
  turned in place is shown turned.

---

## Text Edit

**A gutter** left of the text, from left to right:

- **What changed since the last commit**, as IntelliJ shows it: green beside
  added lines, blue beside changed ones, a red wedge where lines were deleted.
  Shown when Version Tracking is on and the file is in a repository; the
  commit is read again whenever the window comes to the front.
- **What changed since the last save**, in a thinner bar, because Text Edit
  does not save by itself: teal added, orange changed, an orange wedge for
  deleted. Saving clears it. Hovering over the bars explains the colours.
- **Line numbers**, switched by a new button in the bar between absolute,
  relative to the caret's line -- as vi's `relativenumber` -- and off.
  Remembered for every window.
- **Chevrons that fold** JSON, XML, TOML and YAML: an object or array between
  its brackets (`"windows": [ 4 items ]`), an element between its tags, a TOML
  table down to the next, what is indented under a YAML line. Click the badge
  to open it again; Find and typing open it too. **Fold All** and **Unfold
  All** are in the bar. Nothing leaves the text: saving, undo and find see all
  of it.

**The format comes from the extension**: `json`, `xml`, `toml`, `yml` and
`yaml`. **Settings ▸ Behaviour ▸ Text Edit** adds more -- `geojson, jsonc`,
say -- or empties a format to treat its files as plain text.

**A file that breaks its format says where**, as it is typed: a red line
under the bar -- *Not valid JSON — line 12, column 5: A comma or } is expected
after the value* -- with **Show** to go there, the line's number in red, and
the place underlined. A good file shows its format with a green tick. JSON and
TOML are checked completely, XML for being well formed, YAML for the common
mistakes: tabs, a line indented to no level above it, a key under a line that
already has its value, a key set twice, a quote or bracket not closed. After
a problem, only what comes before it folds, until the file is right again.

---

## Columns for pictures and videos

**Settings ▸ Columns** offers what pictures and videos say about themselves,
for every pane and not only a flat view: Format, Date Taken, Date Digitized,
Camera, Lens, Software, Artist, Copyright, Description, ISO, Aperture, Shutter,
Focal Length and its 35mm equivalent, Dimensions, Megapixels, Duration,
Location, Altitude (in metres or feet, as the Mac's region measures), City,
State, Country and Rating. They sort by their values. All are off until
switched on: each reads the header of every picture and video in the folder,
once while the file stays as it is.

- **Arranged in the pane too**: drag a column header left or right to move
  it, Name staying first, and right-click a header for every column in its
  order, to tick on or off. It is the same setting as in Settings, and kept.
  A column with nothing in it for any row of the pane is greyed in that menu,
  and can still be ticked.

## Directory sizes

- **View ▸ Calculate Directory Sizes** works out how much is in every folder
  in the pane, everything under it counted, into the Size column -- in teal,
  so it is not taken for a file's size. Greyed while the Size column is
  hidden; a toolbar button, ∑, can be switched on in Settings ▸ Toolbar.
- **Early, then better**: a folder shows a total once its own files are
  counted, `??` before, and the total grows as what is under it is read. A
  folder counted before counts at its old total, in orange, until it is read
  again, and every folder above follows the difference.
- **In the background, one volume at a time**: it carries on when the pane
  goes elsewhere, the totals are there when it comes back, and a second
  request waits for the first. Kept in memory only. The Info window of a
  folder shows its total too.
- **Sorting by Size** puts a folder by its total as worked out so far, so the
  rows move while the totals grow.
- **View ▸ Clear Directory Sizes** forgets them all and stops the work: `--`
  again.

---

## Values edited in place

- **Click a date, or a picture's or video's value, in a selected row** and
  type over it, as with a name: Return sets it for the whole selection, and
  Undo takes it back.
- **Date Modified and Date Created** for any file or folder; **Date Taken and
  Date Digitized, Lens, ISO, Aperture, Shutter, Focal Length, Software,
  Artist, Copyright and Description** in a JPEG's or HEIC's EXIF; **Date
  Taken, Software, Artist, Copyright and Description** in a QuickTime or MP4
  video.
- **Typed as shown**: `2024-07-14 18:30 +02:00`, `f/2.8`, `1/250 s`, `24 mm`.
  Emptied, a value is removed.

---

## Editing video metadata

- **Right-click ▸ Video ▸ Edit Metadata…** opens the EXIF editor on QuickTime
  and MP4 videos: the same fields, pickers and map -- date taken with its time
  zone, the location in four fields with pasting from a map, camera make and
  model with Control-Space, description, title, artist, copyright, software.
- **The picture and sound are not touched**: they are copied as they are,
  the file is written in place, and Undo puts each video back exactly.
- **No camera fields where they cannot be kept**: an MP4 has no place for a
  make or model, so they are shown only when a QuickTime movie is among the
  videos, or one already has them.

---

## The path bar

- **Hold Option** over the path bar, or while typing in it, and the path
  becomes links, one per folder: **/ Users / verhasp / github**. Click one to
  go there -- several levels up in one click, with the folder you came out of
  selected, as going up does. Let Option go and the text is back, with what
  you had typed and selected.
- **A path typed or pasted is the one linked**: paste the path of a file,
  press Option, and click its folder -- the file selected there.
- **In a flat view, the rows' folders too**: hold Option and the folders before
  each name are links. Click one to go there, the file selected; Back returns
  to the flat view.
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
  disk, and the others: their title and message can be selected, and **⌘C
  copies the selection** (⌘A selects it all). Anywhere else too, ⌘C copies
  the text selected in the window in front, never the files behind it.

---

## The Info window

- **Details**: a picture's or video's place is a link that opens it in Google
  Maps.

---

## Upgrading

A saved expression whose name is now one of the language's words -- `image`,
`video`, `format`, `camera`, `taken`, `near` and the others -- is the word from
now on: `image` is the new test, which knows pictures by their bytes. Diptych
says so as it starts, naming each such file with its full path; to use the
saved one, change the name in its file in `~/.diptych/filters`. Control-Space
no longer offers such a name.

---

*1063 tests.*
