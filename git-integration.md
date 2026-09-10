# Git integration — design

The plan for Diptych's Git support, settled in discussion before any code was
written. This file exists so the work can be picked up cold: it records the
decisions **and the reasons**, because most of the reasons are the sort that
look arbitrary once the argument that produced them is forgotten.

Nothing described here is implemented yet.

## Who it is for

Not developers. People who keep documentation, notes and Markdown in a shared
repository, work with others on it, do not use an IDE, and are not comfortable
with Git. Someone else — a colleague, whoever set up the machine — installed
Git for them and created the remote repository. That person is reachable when
something goes wrong, and the design leans on that: **every failure must be
forwardable**.

Developers already have better tools. Diptych is not competing with them, and
should not grow features that only make sense to someone who knows what an
index is.

## Vocabulary

Used consistently in every string. Git's own words are avoided, including in
menu items, because they are either jargon (`add`, `stage`, `HEAD`) or actively
confusing (`ours`/`theirs`, which swap meaning during a rebase).

| Say | Never say |
| --- | --- |
| my version / **your** version | ours, theirs, local |
| the shared version | origin, remote, upstream |
| Track this file | add, stage |
| Never track this | ignore, .gitignore |
| Send my work | commit, push |
| Get the latest | pull, fetch, merge |
| Earlier versions | log, history, revisions |

The voice matters: Diptych addresses the user, so dialogs say **"your
version"**. The *filename* of a preserved copy says `chapter3 (my version).md`,
because the person who later reads it in their own folder is the one whose
version it is. That mismatch is deliberate; each is correct in its own voice.

## 1. Which Git, and how it is run

### A subprocess, not a library

Diptych runs the `git` program already on the Mac. It does not bundle one, and
it does not link libgit2.

The decisive argument is not performance, it is **authority**: a subprocess
inherits the user's `.gitconfig`, their SSH agent and `~/.ssh/config`, their
credential helper, their hooks, LFS, and their Git version. On the machine this
was designed on the remote is `git@github.com:…` over SSH with
`credential.helper = osxkeychain` — libgit2 would have to reimplement all of
that, badly, and would still not run hooks.

The second argument is that **two engines can disagree**. If colours came from
libgit2 and commits from `git`, the two could differ about `.gitignore`
semantics, `core.excludesFile` or index state, and the app would show one thing
and do another. That is the same class of bug as a pane displaying one directory
while claiming to be in another, which cost a day to find.

### Measured, so the performance question is settled

On this machine, per call:

```
spawn overhead alone            23.4 ms
status,  350 files              45.9 ms   (git's own work 22.4 ms)
status, 1723 files              67.1 ms   (git's own work 43.6 ms)
status scoped to one subdir     42.1 ms   (git's own work ~19 ms)
diff-index --name-status        40.2 ms   (~17 ms)
ls-files --others               43.6 ms   (~20 ms)
```

Three conclusions, none of them guessable:

* **Colouring needs one `status` per *directory*, not per file.** 46–67 ms off
  the main thread, once per navigation. Not a performance problem.
* **Do not compose cheaper primitives.** `diff-index` + `ls-files` beats
  `status` on work (37 ms vs 44 ms) but costs two spawns — 47 ms of overhead
  against 23 ms. Fewer, bigger calls win.
* **Cache repo-wide, not per directory.** Scoping halves Git's work but still
  pays full spawn; one repo-wide status, cached and invalidated by the existing
  kqueue watch plus `.git/index`, makes navigation *within* a repo free.

libgit2 would save the 23 ms spawn and nothing else — and plausibly lose more,
since Git's status benefits from `core.untrackedCache` and `core.fsmonitor`,
which libgit2 has no equivalent for.

### Rules for running it

* **Never discover via `$PATH`.** A GUI app launched from Finder gets a minimal
  PATH, not the user's shell PATH, so discovery would find a different Git
  depending on how Diptych was started. Use an explicit ordered list of
  locations: deterministic, and not manipulable through the environment.
* **Never invoke `/usr/bin/git` blindly.** It is a shim to the selected
  developer directory; on a Mac without Command Line Tools it raises the
  installer dialog. Check `xcode-select -p` first, and never let *detection*
  trigger a system install prompt.
* **Parse machine formats only** — `status --porcelain=v2 -z`,
  `log --format=` with explicit separators. Never parse human or localised
  output. Surface stderr verbatim rather than interpreting it.
* **One command in flight per repository.** Git takes `index.lock`; two
  concurrent commands fail. Serialise per repo, the way transfers already
  serialise in `AppModel`.
* **Everything through `BlockingWork`, with a deadline.** A huge repository or
  one on a network mount can take seconds. "No colours" is an acceptable
  outcome; a stalled pane is not. Same lesson as `DirectoryLoader`.
* **Decorate after the rows are drawn.** The listing must never wait for Git.

## 2. Settings

Off by default. Turning it on shows what was found:

> **Diptych uses the `git` program already on your Mac.** It does not include
> one.
>
> Found: `/opt/homebrew/bin/git`
> Reports itself as: git version 2.54.0
> Digital signature: **none** — not signed by an identifiable developer

The signature is real, checkable information and more useful than any "is this
really Git" test. Measured on this machine:

```
/usr/bin/git             Authority: macOS Software Signing   (Apple)
/opt/homebrew/bin/git    ad-hoc, no authority
/usr/local/git/bin/git   not signed
```

### The warning

Written for someone non-technical, which means naming the *consequence* rather
than using the word "untrusted":

> **Diptych cannot check that this really is Git.** It confirms the file is
> named `git` and that it answers the way Git does, but a harmful program could
> do both of those things.
>
> Whatever this program is, it will be able to read, change and delete files in
> your folders, and send them over the internet — because that is what Git
> itself does.
>
> Only switch this on if you know where this program came from. If you did not
> install it yourself, ask whoever set up your Mac.

### The override

A "Choose…" button. The chosen file **must be named `git`** — and the reason is
stated plainly rather than implied:

> The program must be named `git`. That stops you picking the wrong file by
> accident. **It is not a security check** — a harmful program can be named
> `git` too.

### When nothing is found

> No Git program was found on this Mac, so version tracking stays off. Git is
> normally installed by developers; if you need it, ask whoever set up your
> repository.

Re-resolve at each launch; if the path has gone, disable and say so. Do **not**
pin the binary's hash — a Homebrew upgrade changes it legitimately, and a
warning that cries wolf gets clicked through.

## 3. Colours

The colours answer exactly one question: **what happens to this file when I
send my work?**

| Colour | Meaning |
| --- | --- |
| brown | new — **will not be sent** unless you say so |
| green | new and tracked — will be sent |
| blue | tracked and changed — will be sent |
| red | conflicts with the shared version |
| *none* | nothing to send: unchanged, **or ignored** |

Ignored files are drawn normally. That falls out of the rule consistently — an
ignored file and an unchanged file both answer "nothing happens" — and it stops
a `build/` folder painting half the pane.

Colour goes on the **name text**. The row background is already the Finder tag
band and must not be disturbed.

Source: `status --porcelain=v2 -z --untracked-files=all`. Formats confirmed:
`? path` untracked, `! path` ignored, `1 .M N... 100644 … path` changed.

## 4. The three verbs

### Track this file / Never track this

Context menu on a brown file, offering exactly two futures in plain words.
"Never track this" writes the `.gitignore` line.

### Send my work

**Commit and push are one action.** "Saved here but not shared" is a state with
no place in the user's mental model, and it is exactly where people believe they
have shared when they have not.

One dialog, which is a review step rather than a confirmation:

```
Send my work

Changes to be sent                      [x] (all)
 [x] chapter3.md            (changed)
 [x] notes/outline.md       (changed)
 [x] old-preface.md         (removed)
 [x] appendix.md            (new, tracked)

New files not being sent                [ ] (none)
 [ ] chapter4-draft.md
 [ ] exports/book.pdf

Describe what you changed:
 +--------------------------------+
 |                                |
 +--------------------------------+

                        [ Send ]  [ Cancel ]
```

* Both lists have checkboxes and a tri-state select-all, so a partial send is
  possible. Mechanically `git commit -- <ticked paths>`.
* **New files start unticked.** The recovery from forgetting is one click; the
  recovery from over-sharing a private draft or a 2 GB export is a phone call to
  the helper. The section must be visually loud when non-empty, so it reads as
  "these are being left behind" rather than as a quiet extra.
* Ticking a new file both tracks it and includes it, so "track" is never a
  separate errand.
* Deletions appear in the list as *(removed)*, so they do not read as errors.
* A partial send leaves the unticked files blue. That is correct and
  self-explanatory: the colour keeps telling the truth.

**Send is atomic.** Record HEAD, commit, push. If the push fails, reset back to
the recorded HEAD — the files are untouched, the pane still shows them as
changed, and the button still says *Send my work*. Nothing is left half-done and
there is no hidden "committed but unsent" state.

This is history rewriting, which is otherwise excluded. It is safe here for one
specific reason, which belongs in a comment at the site: **we only ever undo a
commit that provably never left this Mac.**

Guard: a connection that dies *after* the server accepted the push means the
outcome is unknown. Before undoing, fetch and check whether the commit is now on
the shared side; only undo if it genuinely is not. Otherwise we would delete a
commit other people can already see.

Offline is the same path:

> **Your work is saved on this Mac, but not shared yet** — this Mac seems to be
> offline.

### Get the latest

`fetch`, then fast-forward. Never a plain `pull`, which can start a merge and
leave a conflicted tree — precisely where non-experts lose work.

## 5. Conflicts

Everyone is on one branch. The only divergence is *your* main against the shared
main; no branch merging is involved anywhere in this design.

When the fast-forward is refused, **one dialog, one mechanic** — the situation
is the same to the user whether their changes were committed or not:

> **Someone else has changed files that you have also changed.**
>
> These files are different in both places:
> `chapter3.md`
> `notes/outline.md`
>
> Diptych can save **your version** of each one beside it —
> `chapter3 (my version).md` — and then bring the folder up to date with the
> shared version. Both versions will be on disk, side by side.
>
> [ Save my copies and update ] [ Cancel ] [ I will merge this myself ]

"I will merge this myself" does nothing — it is Cancel with a different label,
and exists so the choice is explicit rather than a dead end.

Mechanically the two cases differ only in the command:

* uncommitted edits only → `checkout -- <files>`, then fast-forward
* diverged history → `reset --hard @{u}`

Before a reset, point a bookmark at the old position —
`git branch diptych-kept-2026-09-10` — so dropped commits stay reachable
instead of relying on the reflog, which expires unreachable objects in about 30
days. It is a label, never a branch anyone works on, and it means "nothing is
lost" is literally true. When history diverged, add one sentence to the dialog:

> Some of your changes had already been saved as versions. Those are kept, but
> will no longer be part of the shared history — whoever set up your repository
> can bring them back if you need them.

**The conflicting set is computed exactly**, not approximated as "everything
that differs": files changed on your side since the common ancestor, intersected
with files changed on the shared side since the same ancestor, plus your
uncommitted changes. `git merge-base` gives the ancestor.

Preserved copies go **beside the original**, so the two panes and the diff
viewer can be used on them immediately. The pattern is added to
**`.git/info/exclude`**, not `.gitignore`: local-only, never pushed, no tracked
file modified — so the copies cannot be committed by accident and no
collaborator ever sees the pattern.

Prevention matters more than cure: show "**2 changes online you don't have**" in
the status bar and nudge *Get the latest* before editing. Most conflicts never
happen if you pull first.

## 6. Setup checklist

Rather than failing at the first send, report in plain words whether the folder
is ready. Each line is one cheap command:

```
repo root    git rev-parse --show-toplevel
your name    git config user.name
your email   git config user.email
shared copy  git remote get-url origin
linked       git rev-parse --abbrev-ref @{u}
ahead/behind git rev-list --count --left-right @{u}...HEAD
```

> ✓ This folder is tracked
> ✓ Your name and email are set
> ✓ There is a shared copy online
> ✗ **This folder is not linked to the shared copy** — whoever set up your
>   repository can fix this

A missing piece names *who fixes it* instead of printing `fatal: no upstream
configured for branch 'main'`.

## 7. Every failure is forwardable

The user's next action after a failure is to send it to their helper. So every
error shows a plain sentence **and** a **Copy Details** button carrying the
exact command, the exit code and Git's verbatim stderr. The Git settings pane
has the same button for the whole diagnostic: path, version, signature, repo
root, branch, remote, and the checklist results.

Never paraphrase a failure in a way that hides it. A friendly summary that
swallows `Permission denied (publickey)` makes the problem unfixable.

## 8. Deliberately excluded

Not oversights:

* rebase, cherry-pick, `reset --hard` as a user action, force push, `clean`,
  stash, submodules, tags, remote management
* creating repositories, adding remotes, creating or switching branches —
  that is the helper's job, and it is where non-experts make messes that are
  hard to explain remotely. Diptych reads the setup and acts on **content**
  only.
* merge conflict *resolution*. Detect the state, refuse further operations,
  explain.
* local-only checkpointing. There is no way to save without publishing; for
  people collaborating on documents that is correct, but it is a door being
  closed knowingly.

**Hooks are code execution.** `commit` and `push` run scripts from the
repository. Someone opens a folder a colleague shared, presses *Send my work*,
and runs their code. Developers accept this; for this audience it deserves a
line in the documentation. `--no-verify` is not a good default — it also skips
legitimate checks.

## 9. Order of work

**Slice one** — useful on its own even if nothing follows:

1. `GitRepository`: detection, one repo-wide cached `status`, invalidation,
   deadline, per-repo serialisation
2. Settings: off by default, detection with the disclosure and warning, path
   override restricted to a file named `git`, Copy Details
3. Name colours and a Git column
4. Branch, with "N changes not sent / N you don't have", in the pane status bar
5. The setup checklist

**Then**: Earlier versions window, with Quick Look of an old version
(`show REV:path` into the existing preview scratch directory) and Restore.

**Then**: Send my work, Get the latest, conflicts.

**Then**: word-level diff viewer (`diff --word-diff=porcelain`) — read-only
first. Prose diffs read like tracked changes, where line diffs of a reflowed
paragraph are unreadable. Making it editable later turns it into the merge tool
that option (b) above deliberately leaves to the user.

## Estimates

| Piece | Estimate |
| --- | --- |
| `GitRepository` — discovery, parsing, caching, timeouts, serialisation | 1–1.5 days |
| Colours, Git column, branch, settings switch | ~1 day |
| Earlier versions window with Quick Look of old versions | ~1 day |
| Send / Get the latest / restore, with confirmations and honest errors | 1.5–2 days |
| Word diff viewer | ~1 day |

About a week for all of it; slice one is about two days.
