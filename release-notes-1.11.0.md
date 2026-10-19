# Diptych 1.11.0

A new **Archive** menu makes a zip, a tar archive or an Apple Archive of the
selection, in a window that lists what goes in and offers each format's own
options. Extract unpacks zip, tar and Apple Archive files, and asks before
restoring owners, groups or setuid bits as administrator. **Optimize File
Size** makes photos, PNGs and PDFs smaller, showing each before and after.

---

## Create Archive

- **Archive ▸ Create Archive…**, on a right-click under **Archive**, or the
  toolbar button switched on in Settings ▸ Toolbar. A window lists every item
  selected, with its size, and the archive's name and folder: next to the
  items, or the other pane's.
- **ZIP** is the default, made by `ditto` as Finder's Compress makes it, with
  Mac data -- tags, extended attributes, resource forks, ACLs -- in a
  `__MACOSX` folder. Unticked, the zip holds the bytes and permissions only.
  Compression none, fastest, normal or smallest.
- **tar**, compressed with gzip, bzip2 or xz, or not at all; with or without
  extended attributes, ACLs and file flags; recording the owners as names and
  numbers, numbers only, or root and wheel.
- **Apple Archive** (`.aar`), compressed with LZFSE, LZMA, zlib or LZ4, or not
  at all; owners and groups, extended attributes and ACLs each kept or left
  out.
- **Several items** sit side by side at the top of the archive, from several
  folders too, as a flat view has them. Two of the same name are refused.
- **Nothing half-made shows.** The archive takes its name only once it is
  complete, and Stop leaves nothing behind.
- **A progress bar** while it is made: how many bytes and files of how many,
  the file being packed, and the time left. It moves within one big file
  too.
- What was chosen last is offered next time. Undo moves the archive to the
  Trash.

## Extract

- **Archive ▸ Extract Here** and **Extract to Other Pane**, for zip, tar
  compressed or not, and `.aar`.
- One item at the top comes out as itself, numbered if the name is taken;
  several, in a new folder named after the archive.
- **Unpacked as you first.** When the archive records more than that gave --
  another owner, a group you are not in, a setuid, setgid or sticky bit --
  Diptych lists it and asks: extract without them, or restore them as
  administrator. Restoring unpacks the archive again as root, from a copy
  only root can reach, checked to be the same bytes that were listed.
- What comes out of a downloaded archive is quarantined too.
- Undo moves what was extracted to the Trash.

## Optimize File Size

- **File ▸ Optimize File Size…**, and on a right-click, for JPEG and HEIC
  photos, PNGs and PDFs -- mixed in one selection. Each kind present has its
  own settings: a photo's quality, size and metadata; a PNG's number of
  colours and dithering; a PDF's picture quality and resolution.
- **Every size is real**: each file is optimized as the settings change, and
  the list says what it would save. One that would not get smaller is left
  unticked.
- **Before and after** in one picture, with a line to drag across it and
  zoom to 100 % or 200 %; a PDF page by page.
- **A PDF says what it holds**: its pictures, their resolution now, and how
  many are black and white. A black-and-white scan is left as it is -- as
  JPEG it would only grow.
- **The originals are replaced in place**, keeping their modified date, and
  one Undo puts them all back -- or the smaller files are saved beside them.

## Make PDF

- **Right-click ▸ Image ▸ Make PDF…** makes a PDF of pictures: a page for
  each, and for each page of a multi-page TIFF. One PDF per picture, or one
  of them all in the pane's order.
- The page is the picture's own size, from its resolution, or A4 or US
  Letter. A JPEG goes in as it is, without being compressed again.
- Old-style JPEG TIFFs from scanners and Office Document Imaging work too.

## Quick Look

- **Old multi-page TIFFs** of "old-style JPEG" pages -- as scanners and
  Microsoft Office Document Imaging wrote them -- showed only a thumbnail.
  Every page is shown now, taken out of the file as the JPEG it carries.

## Upgrading

Nothing to do.

---

*1327 tests.*
