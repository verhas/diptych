# Diptych 1.13.0

Diptych connects to **SFTP servers** itself. A server shows as a volume in the
sidebar, its folders as `sftp://` addresses in the panes, and its files can be
copied, moved, renamed, deleted, given new permissions, owner or times, and
edited in place, with any app.

The right-click menu gathers the file tools under **Tools**, with two new
ones: **Convert Line Endings** and **Convert Character Encoding**. **Edit**
opens a file in Text Edit or Bin Edit, whichever fits it. A disk image made
to install from **installs its app** in one click. Text Edit, comparisons and
Quick Look **guess the encoding** of text that is not UTF-8.

---

## Connecting

- **Go ▸ Connect to Server…** takes `sftp://user@host/path`. Diptych signs in
  with the keys in the ssh-agent, then the key files in `~/.ssh`, then asks for
  a password, which it forgets at eject and at quit.
- The first connection shows the server's key, and whether
  `~/.ssh/known_hosts` already trusts it. Diptych keeps its own list in
  `~/.diptych/sftp_known_hosts` and never changes `~/.ssh/known_hosts`. A key
  that changed is refused, with the file and the lines to remove.
- A dropped connection is made again by itself. **Keep Alive…**, in the
  server's sidebar menu, sets how often an idle one is checked; the default
  comes from `ServerAliveInterval` in `~/.ssh/config`, else 60 seconds.

## Working on a server

- The path bar, Copy Path, a dragged file and the MCP tools all give
  `sftp://` addresses. Tab completes server paths.
- Deleting on a server is permanent, and the dialog says so.
- What Split, Join, Create Archive, Extract, Make PDF and the image actions
  make in a server's folder is sent there; what they read is fetched first.
  An archive of a server's folder holds the server's permissions and dates.
  Split and Join write their parts beside the file, not in the other pane.
- Files fetched at the same time are all kept: one could empty another's bytes,
  and an archive made of them came out empty.
- A file made in a server's folder is not emptied by the folder being listed
  while it is sent: a split's parts were, after the first, and never arrived.
- Fetching before Split, Create Archive and the other actions shows how much has
  come, for as long as it runs.
- A large copy to a slow server -- a Raspberry Pi writing to its card -- is no
  longer closed halfway because the server took too long to answer the
  once-a-minute check: bytes still moving count as an answer. A connection
  closed meanwhile no longer stops Diptych.
- Copies to and from a server send many requests at once, as OpenSSH's `sftp`
  does, rather than waiting for the server to answer each 32 KB: much faster
  over Wi-Fi.
- A file that does not arrive whole, either way, is an error that says how much
  of it came, not a shorter file taken as the whole.
- Rename Many, Replace and the one-click transforms rename on the server.
- Find Duplicates searches a server, up to its `/`, fetching only files that
  share a size; the copies chosen are deleted from it, after asking.
- Reveal in Finder warns that it shows the cache; Settings turns that off.
- A saved server in the sidebar shows as connected, and opens when clicked.
- A change of owner the server refuses can be made through `sudo`, for that one
  command; the password is kept as long as you choose, in memory only.
- The Info window shows the server's mode, owner, group and dates, and leaves
  out what SFTP cannot carry: tags, extended attributes, access control lists.

## Files are fetched when they are needed

- A file is fetched when it is opened, previewed, copied, checksummed, or shown
  in Text Edit, Bin Edit or the Info window. The editors and the Info window open
  at once and say they are waiting for it.
- A right-click fetches the small files it was made on; Settings ▸ Behaviour
  sets how small (10 MB by default). A bigger file has **Download to Cache**.
- The new **Cached** column, in server listings only, shows what is kept on
  this Mac and a bar while it arrives; a mark after the name says the same.

## Editing in place

- A saved file is sent back only when the server still has the version that
  was fetched. When it does not, you choose: compare the two (text), save yours
  as a new file beside it, keep yours, keep the server's, or decide later.
- The comparison opens with your side unlocked, and says which side is which.
- After Decide Later, Save asks again without anything new being typed.
- A file sent to the server -- copied, made new, saved under a new name -- is
  kept here as fetched, up to a size of its own in Settings ▸ Behaviour (1000 MB
  by default), apart from the right-click size: one is about disk space, the
  other about waiting.
- A cached file the server lists as changed, at the same size, is checked with
  `sha256sum` or `shasum` run on the server, and not fetched when it is the same.
  Diptych remembers which command each server has.
- The README's *Editing a server's files* says what cannot be caught when
  another app, such as TextEdit, holds unsaved changes while Diptych fetches the
  server's newer version.

## Also

- Reopening a file already open in Text Edit no longer reads it again over
  changes not yet saved.
- Option-Tab no longer brings back windows that were closed.
- The Rename submenu shows F2 only on Rename itself, not on every transform.
- Compare marks its answer: green when the two are the same, yellow when one is
  the start of the other, red when they differ.
- Join Parts is offered with everything selected -- the parts and their manifest
  -- and joins as the manifest says, refusing when a part it lists is not
  selected.
- Compare fetches a server's file before comparing it, rather than comparing the
  empty placeholder of one not fetched yet.
- "Fetching … from the server" counts only what is still to come.
- Paste, with text or a picture on the clipboard and no files, makes a file of
  it, as New from Clipboard does.

## Tools, Edit and conversions

- The right-click menu gathers the file tools under **Tools**: Find Duplicates,
  Archive, Checksum, Split File / Join Parts, and two new ones below.
- **Edit** replaces Text Edit and Bin Edit: a text file opens in Text Edit,
  anything else in Bin Edit. **Edit ▸ Binary Edit** opens a text file in Bin
  Edit.
- **Checksum ▸ Create…** opens a small window listing the files, with a box for
  each kind, MD5 to SHA-512, and a **Do** button. A selected file that is itself
  a checksum file is pointed out in red.
- **Tools ▸ Convert Line Endings…** makes the selected files' line endings LF,
  CRLF, CR, LF CR (Acorn), NEL, LS or PS, in place. The window shows each file's
  line endings now, mixed ones counted, and whether its last line is ended.
- **Tools ▸ Convert Character Encoding…** rewrites the selected files in another
  encoding, with or without a byte-order mark for Unicode. The encoding each is
  taken to be in can be changed, one by one or for all, with a line of the file
  shown to check it by.
- Both refuse a file they cannot convert without loss, and say why. Both are one
  Undo step.

## Installing from a disk image

- A disk image opened in a pane that holds just an application and a link to
  /Applications offers to install it: copied into /Applications after the
  administrator prompt, replacing an older copy, which goes to the Trash.
- It can mark the copy as approved, so it opens without the "downloaded from
  the Internet" question while keeping where it came from; and unmount the
  image and move it to the Trash afterwards.

## Text in other encodings

- Text Edit, comparisons and Quick Look guess the encoding of a file that is
  not UTF-8 -- Latin-2, Windows-1251, Shift JIS and the rest -- instead of
  taking it to be Windows Latin-1. A file too short to tell is read as before:
  Windows Latin-1 in Text Edit, UTF-8 in Quick Look.
- A UTF-16 or UTF-32 file with a byte-order mark opens in Text Edit and
  compares as text, and its mark is written back when it is saved.
- So does one without a mark, told by where its NUL bytes fall, for text that
  is mostly Latin, Greek or Cyrillic.
- A comparison of two files with the same text says what their bytes differ
  in: the character encoding, naming both, a byte-order mark, the line
  endings, or only the last line's ending.
- DOS code pages (437, 850, 852, 866), EBCDIC, KOI8-R and ISO-2022-JP are
  recognised. A guess is taken only when the file is valid in it and its text
  reads like text.

## Upgrading

Nothing to do. The Cached column is on in server listings; Settings ▸ Columns
turns it off.
