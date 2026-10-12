# Distributing scripts

How scripts reach `~/.diptych/scripts`: today, with Diptych itself (version
A, built); later, perhaps also from GitHub, between releases (version B,
designed here and not built).

## The threat this has to answer

The scripts folder rules exist because the danger is not a dishonest author
but **a script that arrived by post**. Diptych therefore refuses anything that
carries the quarantine mark, belongs to somebody else, can be written to, or can
be read by others, and asks before a script first runs.

A built-in downloader is a post box inside the application. Whoever can push to
the repository it reads from -- a stolen token, a taken-over account, a
malicious pull request merged by mistake -- would put code on every Mac that
clicks *Install*, and Diptych would write it with exactly the permissions the
rules ask for, so every check would pass. The question before the first run
helps little: the people this feature is for cannot judge a program by reading
it.

So the question is not *whether* scripts may be fetched, but **where the trust
comes from**. Version A takes it from the application's own signature. Version
B has to bring a signature of its own.

## Version A -- the scripts come with Diptych (built)

- The scripts live in the repository under `Diptych/Scripts/`, and Xcode
  copies them into `Diptych.app/Contents/Resources`. They are signed and
  notarised with the application, so they are trusted exactly as far as
  Diptych is.
- **File ▸ Get Scripts…** (shown while scripts are switched on), and a button
  under the scripts setting in Settings ▸ Behaviour, opens a window listing
  them: name, description, version, and how each stands against the folder.
  Nothing is ticked to begin with. **Show Source** shows a script in full;
  **Compare with Yours** opens the two-file comparison on the installed file
  and a copy of the new one.
- **Installing** writes each file as `r--------`, owned by the user, under a
  hidden name, and renames it into place. Diptych writes it itself, so it
  carries no quarantine mark. A file already there under the same name goes to
  the **Trash** first; nothing is overwritten. The folder is then read again,
  so the scripts are in the menus at once, and each is still asked about
  before it first runs.
- **No network activity** at all. A new or changed script arrives with the
  next Diptych, through the update check that already exists.

### Headers

Two headers, which every script that comes with Diptych carries:

```sh
# source: diptych
# version: 3
```

- `source` names where a script was published. Only `diptych` is used.
- `version` is a whole number from 1, raised by one for every change.

How a script stands against the folder:

| Shown | When |
| --- | --- |
| *version 3* | nothing of that name is installed |
| *installed, version 3* | the installed file is byte for byte this one |
| *version 2 installed -- 3 is newer* | the installed file says `source: diptych` and a lower version |
| *a different file of this name is installed* | anything else: the user's own script, ours changed by hand, or a later version |

A third header, `signature`, is **accepted and ignored** from this version on,
so a signed script written for version B is not reported as a mistake by a
Diptych that cannot yet check it.

## Version B -- scripts from GitHub, signed (designed)

The point is a release cycle of the scripts' own: a new script, or a fix, without
a new Diptych. Everything in version A stays; B adds a second place the same
window reads from, and a signature that makes reading from it safe.

### One signature per script, in its header

```sh
#!/bin/sh
# name: Make a zip of these
# description: Puts what is selected into untitled.zip, beside it.
# apply-to: file, directory, link
# args: 1,
# call: $0 $@
# source: diptych
# version: 3
# signature: ed25519 diptych-2026 Kp3v…Qg==
set -eu
…
```

**What is signed: the exact bytes of the file with the signature line removed**,
its line feed included -- the shebang, every header and the body. Not the body
alone: the headers are code too.

- `# call:` builds the command line, and its first word need not be `$0`:
  `# call: rm -rf $@` is a valid header. A signature over the body alone would
  survive that line being swapped.
- `#!` chooses the interpreter that runs the body.
- `# apply-to:`, `# only-in:`, `# only-under:` and `# args:` decide what a
  script is aimed at; widening `only-under: ~/Documents` to `/` turns a
  harmless script into one that runs anywhere.
- `# version:` must be covered, or an old signed copy could be passed off as
  the newest.

The line is `ed25519`, a **key name**, and the 64-byte signature in base64 (88
characters). The key name lets Diptych trust several public keys at once, so a
key can be replaced without making every published script invalid on the same
day.

Rules for the verifier:

- **Exactly one** signature line, among the header lines. Two are refused: one
  of them is not covering what it seems to.
- **No normalisation**: the bytes are verified as they are. The repository must
  keep LF line endings (`.gitattributes`: `*.sh text eol=lf`), or a checkout
  that converts them breaks every signature.
- Verified with CryptoKit's `Curve25519.Signing.PublicKey.isValidSignature`,
  against public keys **compiled into Diptych** -- never against a key fetched
  alongside the script.

### Why in the file, not in a manifest

A signed list of hashes would serve downloading equally well. A signature in
the file does more:

- **It travels with the file.** A script mailed, copied or fetched by hand can
  still be checked, and Diptych can check it whenever it reads the folder and
  before every run, not only once at installation.
- **Editing is noticed for free.** A user who edits a signed script breaks its
  signature; from then on it is *their* script. It runs under the usual rules,
  is no longer labelled as Diptych's, and is never offered an update over it.
  This replaces the guesswork in A's *a different file of this name*.
- **The approval question can say more**: *Signed by Diptych, version 3*, or
  *Not signed*. It still asks either way -- a signature says who wrote a script,
  not that it is the right thing to run on these files.

The scripts that come with the application (A) are signed the same way, so the
file in the app and the file on GitHub are one and the same.

### Fetching

- **From where:** a fixed HTTPS location in the Diptych repository, for example
  `raw.githubusercontent.com/<owner>/diptych/scripts/` on a branch kept for
  them, with an `index.json` listing file name, name, description and version.
- **The index is not trusted.** It only says what exists. Every decision --
  install, update, label -- is taken on the downloaded script after its
  signature checks out. A forged index can hide scripts or lie about versions,
  which is a nuisance, not a breach: whatever it points to still has to verify.
- **Asked first**, the way the update check is. The first time the window would
  reach the network it says so: *Only the list of scripts is fetched from
  GitHub; nothing is installed without asking.* A setting keeps the answer:
  *ask*, *look when Get Scripts opens*, or *never*, in which case the window
  shows the scripts that came with Diptych only.
- **TLS protects the transfer; the signature protects the content.** The design
  does not rely on GitHub, its CDN or the connection being honest.
- Written by Diptych from the downloaded bytes, so no quarantine mark -- and
  that is acceptable only because the signature check takes its place. **A
  script whose signature does not verify is never written to disk.**

### Going backwards

A validly signed old version is still validly signed. To stop a stale copy,
with a bug long since fixed, being offered as the newest, Diptych keeps **the
highest version it has installed of each script** in
`~/.diptych/scripts-installed.json`, and refuses to install a lower one. The
version is a signed header, so it cannot be raised without the key.

### Updates

- Looked for when the window opens, and -- if the user agrees -- at most once a
  day at startup, together with the existing update check.
- **Never installed silently.** An available update is *said*: a line in the
  window, or a notice. The user opens Get Scripts, compares the installed
  script with the new one in the comparison window, and installs it. A replaced
  script has new contents, so it is asked about again before it runs anyway.
- Offered only over a script whose signature still verifies and says
  `source: diptych`. A script the user changed is theirs and is left alone.

### The key

Everything rests on the private key, which therefore never touches the
repository, CI, or a shared machine.

- **Signing:** `sign-script.swift` in the repository, run by hand on the
  release machine: it reads the private key from the login Keychain (or an
  offline file), removes any old signature line, signs, and writes the new line
  back into the header.
- **Checking before publishing:** `./build.sh test` verifies every script under
  `Diptych/Scripts/` against the public keys, so an unsigned or stale script
  fails the build rather than reaching users.
- **Replacing a key:** a new key name is added to the application's list in one
  release, scripts are signed with it in the next, and the old one is dropped
  after that. A key that may have leaked is removed in an immediate release;
  scripts signed with it then show as *not signed*.

### What changes in the code

| Piece | Work |
| --- | --- |
| `ScriptDefinition` | parse the signature line; keep the signed bytes |
| `ScriptSignature` (new) | the message, the check, the trusted keys |
| `ScriptLibrary` | a second source: the GitHub index and downloads, with consent and the rollback record |
| `ScriptCatalogue` | the *signed* label, checked at reading and before running |
| `GetScriptsView` | a *Diptych* / *GitHub* origin per row, *signed* / *not signed*, update notices |
| approval dialog | *Signed by Diptych, version N* or *Not signed* |
| `sign-script.swift`, tests | signing, and a build-time check of every bundled script |

The order follows from it: signing and verifying first, with the bundled
scripts signed and checked by the tests -- useful on its own, since it labels
them and notices edits -- and the download only after that.
