# Diptych 1.3.3

A new feature, and two fixes, both found by using the app rather than by
reading the code.

---

## Checking for updates

Diptych can now check GitHub for a newer release — off by default, and
asking first. The very first time it matters, a small window offers three
choices: check whenever Diptych starts, at most once a day; not now; or
don't ask again. Nothing is sent anywhere until one of those is chosen.

With checking on, it looks at most once a day, and silently — nothing is
shown unless there is genuinely something newer. If there is, a window
names it and asks before doing anything. Saying no changes nothing; it asks
again tomorrow.

Saying yes downloads the new version's disk image to `~/Downloads` and opens
it — mounting it and showing the Finder window it arrives in, ready to drag
into Applications — then Diptych quits on its own. No window of its own is
shown from the moment you say yes to the moment it quits, and the quit
itself asks nobody, even with "Ask before quitting" switched on: this is the
one case where that question would only be in the way.

---

## The path bar has its own menu again

Right-clicking the path bar showed the pane's own empty-space menu — New
Folder, Paste, and the rest — because the click router asked a table "is this
below your last row?" and a table answers that the same way for *anywhere
outside itself entirely*, the path bar included, as it does for genuinely
empty space beneath a short list. It now also checks that the click actually
landed inside the table before asking that question at all.

The path bar's own menu has one item: **Add to Favourites**. It is also the
only way to add `/` itself to the sidebar — nothing about a pane's own root
can be dragged there the way a row inside one can.

---

## Dragging a file out no longer hands over a URL

Dragging a row onto Terminal, or anywhere else that takes a dropped file as
plain text, pasted `file:///Users/…` — letter for letter — where the same
file dragged out of Finder pastes the plain path. Sniffing the actual drag
pasteboard against Finder's own turned up two differences, both now removed:

- **File-promise metadata that has no business being there.** A promise is
for content that does not exist as a file yet and has to be produced on
demand; this is an existing file with a stable path, exactly what Finder
drags, and Finder's own drag carries none of that. Something on the
receiving end evidently treats a promised drag differently than a plain
one.
- **A generic URL type Finder's drag never carries at all**, alongside the
file-specific one. Offering both looks to be read as "this is a link", not
"this is a file".

The drag now carries only the plain path and the file's own URL, matching
what Finder puts on the pasteboard for an existing file.

---

## Upgrading

Nothing to do. Update checking starts switched off, the same as everything
else that reaches the network without being asked first.

---

*747 tests.*
