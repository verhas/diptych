# Diptych 1.13.0

Diptych connects to **SFTP servers** itself. A server shows as a volume in the
sidebar, its folders as `sftp://` addresses in the panes, and its files can be
copied, moved, renamed, deleted, given new permissions, owner or times, and
edited in place, with any app.

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
  as a new file beside it, keep yours, or keep the server's.
- The README's *Editing a server's files* says what cannot be caught when
  another app, such as TextEdit, holds unsaved changes while Diptych fetches the
  server's newer version.

## Also

- Reopening a file already open in Text Edit no longer reads it again over
  changes not yet saved.

## Upgrading

Nothing to do. The Cached column is on in server listings; Settings ▸ Columns
turns it off.
