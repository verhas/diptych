# Previews for 2.0.0 — file formats

Formats where Quick Look shows nothing useful — an icon or raw bytes — but
the file has a structure worth showing. Each gets an HTML report like the
existing ones (`*Report.swift` in `Diptych/Support`, dispatched from
`QuickLook.swift`).

Already done before 2.0.0: folders and archives (`ListingReport`), symbolic
links and aliases (`LinkReport`), `.DS_Store` (`DSStoreReport`), plists
(`PlistReport`), old JPEG/TIFF, Markdown (`MarkdownReport`).

## Ground rules for every report

- Parse only: never run, load, mount or install the file.
- Never ask for a password. Show what can be read, say plainly what cannot.
- Cap the bytes read; above the cap, say so and show what was read.
- Never show secret material (private keys, secret-key entries).
- Recognise the format by its leading bytes ("magic"), not only by the extension.
- Tests with generated fixtures only, never real user files.

## Status

Status values: `planned`, `in progress`, `done`, `dropped`.

| # | Format | Tier | Status | Version | Notes |
|---|--------|------|--------|---------|-------|
| 1 | Java `.class` | 1 | done | 2.0.0 | `ClassFile`, `JavaSignature`, `ClassFileReport` |
| 2 | `.jar` / `.war` header | 1 | planned | | on top of the archive listing |
| 3 | Key stores `.jks` `.keystore` `.p12` `.pfx` | 1 | planned | | |
| 4 | Certificates and keys `.cer` `.crt` `.pem` `.der` `.csr`, SSH `.pub` | 1 | planned | | |
| 5 | Unix executables: Mach-O, ELF, scripts | 1 | planned | | |
| 6 | `.app` bundles | 1 | planned | | |
| 7 | SQLite databases | 2 | planned | | |
| 8 | Installer packages `.pkg` | 2 | planned | | |
| 9 | Disk images `.dmg` | 2 | planned | | |
| 10 | Crash reports `.ips` | 2 | planned | | |
| 11 | `.mobileprovision` | 2 | planned | | |
| 12 | `.webloc` `.inetloc` `.url` | 2 | planned | | |
| 13 | JSON, `.jsonl`, YAML, TOML | 3 | planned | | |
| 14 | Git repository folders | 3 | planned | | in the folder report |
| 15 | `.properties` | 3 | planned | | |
| 16 | `.eml` / `.mbox` | 3 | planned | | |
| 17 | Where it came from (any file) | 3 | planned | | a section, not a format |

Suggested first five for 2.0.0: 1–2, 3–4, 5–6, 7, 8.

---

## 1. Java `.class`

Recognised by: the `.class` extension and magic `CA FE BA BE` followed by a
class-file version. Mach-O universal binaries start with the same four bytes:
there the next word is an architecture count, never as high as 45, the first
class-file version (`ClassFile.looksLikeClass`).

- [x] Class name, superclass, interfaces, access flags (public, final, abstract, interface, enum, record, annotation, sealed)
- [x] Class-file version and the Java release it means (52 = 8, 55 = 11, 61 = 17, 65 = 21, …), preview-features flag
- [x] Fields: modifiers, generic type, name, constant value typed by the field (`'q'`, `true`, `1L`, `"text"`)
- [x] Methods: modifiers, generic signature, parameter names (`MethodParameters` or the `-g` local-variable table), varargs, `throws`
- [x] `SourceFile`, `Signature` (generics), `Record`, `PermittedSubclasses`, `NestHost`, `InnerClasses`, `EnclosingMethod`
- [x] Annotations, runtime-visible and class-file-only, with their values (long ones cut)
- [x] `module-info.class` as the module declaration (requires, exports, opens, uses, provides)
- [x] Folded: compiler-made members, classes it uses, string literals in the code
- [x] Parsed directly, no JDK needed; a damaged file gets a page saying what is wrong
- [ ] Not done: parameter annotations; a nested record or enum listed under Nested Classes shows as `class` (InnerClasses does not say)

Code: `Diptych/Support/ClassFile.swift` (reader), `JavaSignature.swift`
(descriptors and generic signatures), `ClassFileReport.swift` (page),
dispatch in `QuickLook.swift`. Tests: `DiptychTests/ClassFileReportTests.swift`
with fixtures compiled from made-up sources in `ClassFileFixtures.swift`.

## 2. `.jar` / `.war` header

Recognised by: archive with `META-INF/MANIFEST.MF`, or the extension.
Shown above the existing archive listing.

- [ ] `MANIFEST.MF`: Main-Class, Automatic-Module-Name, Multi-Release, Class-Path, Implementation-*
- [ ] Signed or not (`META-INF/*.SF` / `.RSA` / `.EC`), and by whom
- [ ] Maven coordinates from `META-INF/maven/**/pom.properties`
- [ ] `module-info.class`: module name, requires, exports
- [ ] Range of class versions inside ("classes for Java 11–17")
- [ ] Multi-release versions present (`META-INF/versions/N`)

## 3. Key stores

Recognised by: JKS magic `FE ED FE ED`, JCEKS `CE CE CE CE`, PKCS#12 DER
`30 …` with the PKCS#12 structure.

- [ ] Each alias: entry type (private key, trusted certificate, secret key), date added
- [ ] For each certificate: subject, issuer, validity, expired / expiring within 30 days highlighted, SHA-256 fingerprint
- [ ] Certificate chains under private-key entries
- [ ] JKS/JCEKS: certificates read without a password; integrity not checked (needs the password) — say so
- [ ] PKCS#12 fully encrypted: "encrypted, N bytes, needs a password", no prompt
- [ ] Never show key material

## 4. Certificates and keys

Recognised by: PEM `-----BEGIN …-----` headers; DER by structure; SSH by
`ssh-ed25519` / `ssh-rsa` / `ecdsa-sha2-…` prefix.

- [ ] Certificates: subject, SANs, issuer, validity, key type and size, signature algorithm, fingerprints, CA / not CA
- [ ] PEM bundles: every certificate, shown as a chain where they link
- [ ] Certificate requests (`.csr`): subject, SANs, key type and size
- [ ] SSH public keys: type, bits, SHA-256 fingerprint, comment (as `ssh-keygen -l`)
- [ ] Private keys: type and whether passphrase-protected — nothing else

## 5. Unix executables

Finder's "Unix executable" is four things; decide by magic.

- [ ] **Mach-O** (`FE ED FA CF`, `CF FA ED FE`, universal `CA FE BA BE`):
  - [ ] architectures (each slice of a universal binary), file type (executable, dylib, bundle)
  - [ ] minimum macOS and SDK (`LC_BUILD_VERSION` / `LC_VERSION_MIN_*`)
  - [ ] linked libraries (`LC_LOAD_DYLIB` and weak/re-export variants), rpaths
  - [ ] UUIDs
  - [ ] code signature: signed or not, ad hoc, Team ID, identifier, hardened runtime, notarization ticket, entitlements
- [ ] **ELF** (`7F 45 4C 46`): class, architecture, static or dynamic, interpreter, needed libraries
- [ ] **Scripts** (`#!`): the interpreter line, then the text
- [ ] **Text with the execute bit**: shown as text, with a note that it is marked executable

## 6. `.app` bundles

Currently skipped on purpose (`isPackage`), so Quick Look shows the icon.

- [ ] Name, version, build, bundle identifier, category, copyright (from `Info.plist`)
- [ ] Main executable: architectures, minimum macOS (as Mach-O above)
- [ ] Code signature and notarization, Team ID, entitlements
- [ ] Size on disk; embedded frameworks, plug-ins, login items, helper tools
- [ ] Quarantine / translocation status

## 7. SQLite databases

Recognised by: `SQLite format 3\0` header (many app databases have other extensions).

- [ ] Tables, views, indexes, triggers with their schema
- [ ] Row count per table
- [ ] First N rows of each table, long values shortened, blobs as size
- [ ] Opened read-only (`SQLITE_OPEN_READONLY`, immutable URI) — never touches `-wal` / `-shm`
- [ ] Encrypted / not a database: said plainly

## 8. Installer packages `.pkg`

Recognised by: xar magic `78 61 72 21` (flat packages), or bundle packages.

- [ ] Title, identifier, version, signature and notarization
- [ ] Components and where each installs
- [ ] Files installed (from the Bom), totals
- [ ] Pre- and post-install scripts, shown in full — the safety question before installing
- [ ] Distribution: requirements, choices

## 9. Disk images `.dmg`

- [ ] Format (UDZO, UDBZ, ULFO, ULMO, sparse …), compressed and full size
- [ ] Encrypted or not
- [ ] Code signature and notarization of the image
- [ ] Partition scheme / file system if readable without mounting
- [ ] No mounting

## 10. Crash reports `.ips`

Recognised by: a JSON header line followed by a JSON body.

- [ ] Process, version, OS, hardware, date
- [ ] Exception type, codes, termination reason
- [ ] Crashed thread's stack, readable; other threads collapsed
- [ ] Binary images list (collapsed)

## 11. `.mobileprovision`

Recognised by: CMS-signed plist.

- [ ] Name, app identifier, team, creation and expiry (expired highlighted)
- [ ] Entitlements
- [ ] Devices (count, list collapsed), or "all devices" / App Store
- [ ] Developer certificates: subject and expiry

## 12. `.webloc` `.inetloc` `.url`

- [ ] The target URL, clickable
- [ ] `.url` (Windows INI form) parsed as well as the plist forms

## 13. JSON, `.jsonl`, YAML, TOML

- [ ] Formatted, collapsible tree
- [ ] Syntax error: line, column and the text around it
- [ ] `.jsonl`: one entry per line, counted
- [ ] Size cap with "first N KB shown"

## 14. Git repository folders

In the existing folder report.

- [ ] Branch, upstream, ahead/behind
- [ ] Uncommitted changes (count, list collapsed)
- [ ] Last few commits
- [ ] Reuse what `git-integration.md` already describes

## 15. `.properties`

- [ ] Keys and values as a table
- [ ] `\uXXXX` escapes decoded, line continuations joined
- [ ] Comments kept

## 16. `.eml` / `.mbox`

- [ ] `.eml`: headers (From, To, Date, Subject), body as text, attachments listed with sizes
- [ ] `.mbox`: one row per message, opened from the list

## 17. Where it came from (any file)

A section added to every report, from extended attributes.

- [ ] `com.apple.metadata:kMDItemWhereFroms`: download URL and referring page
- [ ] `com.apple.quarantine`: quarantined, by which app, when
- [ ] Other extended attributes listed by name and size

---

## Log

Newest first. One line per change: date, format #, what was done.

| Date | # | Done |
|------|---|------|
| 2026-11-13 | 1 | Java `.class` preview: reader, generic signatures, page, 18 tests |
| 2026-11-13 | — | Document started |
