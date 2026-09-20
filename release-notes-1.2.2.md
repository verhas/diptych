# Diptych 1.2.2

Four fixes around the filter box and the path bar, all of them reported from
everyday use.

---

## The filter box no longer keeps the keyboard

Type something in the filter, then click one of the files it leaves showing:
the row selected **grey rather than blue**, and F5, F6 and every other key did
nothing. The keyboard still belonged to the text field, and Diptych
deliberately never takes keys from a text field — Return in the path bar must
mean "go there", not "open this". Clicking the other pane and back was the only
way out.

A click in a list now takes the keyboard, and says which pane it was in. Both
halves were needed: which pane is *active* follows SwiftUI's own focus, and
that does not notice a first responder set from AppKit — so with only the first
half the row went blue while F5 still copied from the other pane, and did
nothing at all.

---

## A filter no longer freezes the selection

Worse, and underneath it: once a filter was typed, **the selection never
reached the application at all.** The rule that a greyed-out row cannot be
selected rewrote the selection from inside that property's own observer, while
SwiftUI was delivering the change to it. From then on the two disagreed
permanently — the list highlighted whatever was clicked while Diptych held
nothing, so the status line said nothing was selected and every command had
nothing to act on.

The correction now happens a turn of the run loop later. It still applies, and
it no longer fights.

---

## A greyed-out row does not open

Double-clicking a file the filter excludes opened it. It cannot be selected,
copied or moved, so opening it made the greying look like decoration. It now
says so instead: *"other-c.txt" does not match the filter*.

---

## The path bar's selection is blue again

Clicking the path bar, or Go to Folder, selects the whole path — and it was
drawn grey, which reads as a field that is not really focused. That grey
belongs to a pending **completion**: what Tab would take, rather than what you
chose. It was set on the editor once and never taken off. Grey now marks the
suggestion alone.

---

## Upgrading

Nothing to do; this release only fixes things.

---

*671 tests.*
