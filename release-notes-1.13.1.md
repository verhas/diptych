# Diptych 1.13.1

**Apple Intelligence explains comparisons.** Compare Folders shows a short
summary of how the two folders differ, and the file comparison explains what
changed between the two files. Both are worked out in the background by the
model on this Mac. **New from Clipboard** saves a picture in the format the
folder already uses, and gives text the extension of what it is. Four new
scripts use Apple Intelligence instead of an agent.

---

## Compare Folders: a summary

- With Settings ▸ **Use Apple Intelligence** on, a box between the checkboxes
  and the list says in a few sentences what was added, removed or changed,
  and any pattern, such as one side being a newer copy.
- It is asked in the background each time a comparison finishes, Refresh
  included. The list can be used while it is on its way.
- The model gets file names, sizes, dates and which properties differ, never
  what is in the files. A folder found on one side only is described once,
  not file by file.

## Comparing two files: an explanation

- Under the line with find and the count of differences, a box explains what
  the changes mean -- a value changed, a section added -- rather than
  repeating the lines.
- The model reads the diff: each change with two lines around it, up to about
  6,000 characters. If that is still too much for it, it is asked once more
  with half as much.
- It is asked again when the comparison changes: *ignore spacing*, a file
  changed elsewhere, or a pause of a second and a half in typing on the
  unlocked side.

## New from Clipboard

- With *Save a picture as* set to **Ask each time**, the dialog offers first
  the format most pictures in the folder already are -- PNG, JPEG or PDF -- and
  Return chooses it. A folder with none of them still offers PNG.
- Pasted text is saved as `.md`, `.json`, `.yaml`, `.csv`, `.sh`, `.py`,
  `.swift` and so on, from what Apple Intelligence says the text is, instead of
  always `.txt`.

## Scripts with Apple Intelligence

- **Get Scripts** has four new ones: *Explain with Apple Intelligence* (a
  report beside a PDF), *Summarize with Apple Intelligence*, *Suggest a Name
  with Apple Intelligence* and *Describe with Apple Intelligence* (pictures).
- They use `fm`, the Foundation Models command line of macOS 27, always with
  the model on this Mac. Run `sudo fm license` once before the first use.

## Privacy

Everything above uses the system model on this Mac, named explicitly, never
Private Cloud Compute, so nothing is sent anywhere. With **Use Apple
Intelligence** off, the comparison windows show no box and pasted text is
saved as `.txt`. The scripts run only when you run them.

## Upgrading

Nothing to do. Apple Intelligence stays off until it is turned on in Settings,
and a picture setting other than *Ask each time* is used as before.
