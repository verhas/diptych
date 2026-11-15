commit and push chan# Previews for 2.0.0 — file formats

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

Status values: `planned`, `in progress`, `done`, `dropped`, `moved` (taken
out of this plan, to the document named in its notes).

| # | Format | Tier | Status | Version | Notes |
|---|--------|------|--------|---------|-------|
| 1 | Java `.class` | 1 | done | 2.0.0 | `ClassFile`, `JavaSignature`, `ClassFileReport` |
| 2 | `.jar` / `.war` / `.ear` header | 1 | planned | | `.ear` now gets the archive listing too |
| 3 | Key stores `.jks` `.jceks` `.keystore` `.ks` `.truststore` `.p12` `.pfx` | 1 | done | 2.0.0 | `KeyStore`, `PKCS12`, `X509`, `DER`, `KeyStoreReport` |
| 4 | Certificates and keys `.cer` `.crt` `.pem` `.der` `.csr` `.crl` `.p7b`, SSH keys | 1 | done | 2.0.0 | `CertificateFile`, `SSHKey`, `CertificateReport` |
| 5 | Executables: Mach-O, ELF, Windows PE, libraries, scripts, batch files | 1 | done | 2.0.0 | `MachOFile`, `ELF`, `PEFile`, `ArArchive`, `Script`, `ExecutableReport` |
| 6 | `.app` and other code bundles | 1 | done | 2.0.0 | `AppBundle`, `BundleReport` |
| 7 | SQLite databases | 2 | planned | | a window of its own; Quick Look a static summary |
| 8 | Installer packages `.pkg` | 2 | done | 2.0.0 | `XarArchive`, `Bom`, `CPIO`, `InstallerPackage`, `PackageReport` |
| 9 | Disk images `.dmg` | 2 | done | 2.0.0 | `DiskImage` (UDIF, raw, sparse, HFS+, APFS), `DiskImageReport` |
| 10 | Crash reports `.ips` | 2 | done | 2.0.0 | `CrashLog`, `CrashReport` |
| 11 | `.mobileprovision` | 2 | done | 2.0.0 | `ProvisioningProfile`, `ProvisioningReport` |
| 12 | `.webloc` `.inetloc` `.url` | 2 | done | 2.0.0 | `InternetLocation`, `Punycode`, `LocationReport` |
| 13 | Syntax-formatted text: JSON, YAML, TOML, programming languages, CSS, HTML… | 3 | planned | | TextMate grammars, one engine for Quick Look and Text Edit |
| 14 | Git repository folders | 3 | planned | | in the folder report |
| 15 | `.properties` | 3 | done | 2.0.0 | `JavaProperties`, `PropertiesReport` |
| 16 | `.eml` / `.mbox` | 3 | done | 2.0.0 | `MailMessage`, `Mailbox`, `MailReport` |
| 17 | Where it came from (any file) | 3 | moved | | not a format: `where-it-came-from.md` |

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

Recognised by: JKS magic `FE ED FE ED`, JCEKS `CE CE CE CE`, PKCS#12 a DER
SEQUENCE with version 3 -- from the bytes, whatever the extension says.

- [x] Each alias: entry type (private key, trusted certificate, secret key, certificate), date added (JKS/JCEKS)
- [x] For each certificate: subject, issuer, validity, expired / expiring within 30 days / not valid yet marked, key type and size, signature algorithm, CA or not, alternative names, serial, SHA-256 and SHA-1 fingerprints
- [x] Certificate chains under private-key entries (PKCS#12: by local key ID, then up by issuer)
- [x] Default passwords tried, never asked for: empty and `changeit`; the page says when one opens the store
- [x] JKS/JCEKS: certificates read without a password; integrity checked when a default password fits
- [x] JCEKS secret keys: the serialized Java object stepped over (`JavaSerialization`), its sealing algorithm named
- [x] PKCS#12: MAC verified (HMAC-SHA1…SHA512, RFC 7292 key derivation); encrypted parts opened with a confirmed default password -- PBES2/PBKDF2/AES/3DES and the legacy SHA-1 3DES/RC2 -- otherwise named and left shut
- [x] PKCS#12 with no MAC (JDK `cacerts`, `-J-Dkeystore.pkcs12.macAlgorithm=NONE`): said to have no integrity check
- [x] Never shows key material; an unencrypted key bag is flagged in red
- [ ] Not done: PBMAC1 MACs (RFC 9579) are named, not verified; public-key-enveloped PKCS#12 parts are named, not read

Code: `Diptych/Support/DER.swift`, `X509.swift`, `KeyStore.swift` (model, JKS/JCEKS,
Java serialization), `PKCS12.swift`, `KeyStoreReport.swift`, dispatch in `QuickLook.swift`.
Tests: `DiptychTests/KeyStoreReportTests.swift`, fixtures in `KeyStoreFixtures.swift`.
Samples: `make-java-samples.sh` (also writes a `.ear` and compiled classes).

## 4. Certificates and keys

Recognised by: PEM `-----BEGIN …-----` labels; DER by structure (certificate,
request, CRL, PKCS#7, PKCS#8, SubjectPublicKeyInfo, PKCS#1); SSH by key-type
prefix, `openssh-key-v1`, RFC 4716 markers, and SSH-1's decimal form.
Extensions `.cer .crt .pem .der .cert .csr .req .crl .p7b .p7c .key .pub`, and
`id_*` / `authorized_keys`. A `.key`/`.pub` that holds no key falls back to
Quick Look (Keynote, Publisher).

- [x] Certificates: subject, SANs (IPv6 per RFC 5952), issuer, validity, key type and size, signature algorithm, key usage and extended key usage, CA / not CA, serial, fingerprints
- [x] PEM bundles and PKCS#7 (`.p7b` DER, `.p7c` PEM): every certificate, each linked to its issuer in the file; in chain order / out of order / a bundle, said
- [x] Certificate requests: subject, SANs, key, signature algorithm, challenge password present (never shown)
- [x] Revocation lists: issuer, issued, next update (overdue marked), number, revoked serials with dates and reasons; a certificate in the same file that is revoked is marked
- [x] Private keys: PKCS#8, encrypted PKCS#8, PKCS#1, SEC1, OpenSSL's encrypted PEM (Proc-Type/DEK-Info), DER -- type, size, protection, never the key
- [x] Private key ↔ certificate in the same file: matched by RSA modulus or public point (EC and Ed25519 public halves derived when not written)
- [x] Public keys: SubjectPublicKeyInfo and PKCS#1, with the certificate they belong to
- [x] EC and DH parameters named
- [x] SSH public keys: type, bits, SHA-256 fingerprint identical to `ssh-keygen -l`, comment; `authorized_keys` options; RFC 4716
- [x] OpenSSH private keys: passphrase cipher and KDF rounds, public half and fingerprint, comment when unencrypted
- [x] SSH certificates: user/host, key ID, serial, principals, validity, critical options, extensions, signing CA fingerprint (as `ssh-keygen -L`)
- [x] SSH protocol 1 RSA keys recognised and called obsolete
- [ ] Not done: PuTTY `.ppk` (no puttygen here to make samples); `known_hosts`; signature verification of certificates, requests and CRLs

Code: `Diptych/Support/CertificateFile.swift`, `SSHKey.swift`, `CertificateReport.swift`,
with `X509.swift` and `DER.swift` from #3; dispatch in `QuickLook.swift`.
Tests: `DiptychTests/CertificateReportTests.swift`, fixtures in `CertificateFixtures.swift`.
Samples: `make-certificate-samples.sh` (into `test_folder/18-certificates`).

## 5. Unix executables

Finder's "Unix executable" is four things; decide by magic. Looked at when
the file has no extension, one binaries use (`dylib`, `so`, `o`, `bundle`,
`node`, `command`, …), or one no application declares (`libc.so.6`).

- [x] **Mach-O** (`FE ED FA CE/CF`, `CE/CF FA ED FE`, universal `CA FE BA BE/BF`):
  - [x] architectures (each slice of a universal binary), file type (executable, dylib, bundle, object, …)
  - [x] minimum OS and SDK (`LC_BUILD_VERSION` / `LC_VERSION_MIN_*`), build tools, source version
  - [x] linked libraries (`LC_LOAD_DYLIB` and weak/re-export/lazy/upward), install name, rpaths
  - [x] UUIDs, segments and sections (folded)
  - [x] code signature: Apple / Developer ID / development / ad hoc / linker-signed, certificate chain, signing time, identifier, Team ID, hardened runtime, platform binary, entitlements (named in words)
  - [x] every code page and the signed requirements and entitlements hashed and compared (up to 512 MB)
  - [x] warnings: changed after signing, unsigned on Apple silicon, Intel only (Rosetta), 32-bit/PowerPC, newer macOS needed, FairPlay encrypted
  - [ ] Not done: notarization (online; the Info window's Signature tab runs `spctl`), the CMS signature itself is not verified, requirements shown as text
- [x] **ELF** (`7F 45 4C 46`): class, byte order, system, machine, kind, static or dynamic, interpreter, needed libraries, soname, rpath/runpath, glibc/libstdc++ versions needed, minimum kernel, build ID, stripped or not, executable stack, Go/Rust, segments and sections
- [x] **Scripts** (`#!`): interpreter, `env` followed (also `-S`), found on this Mac or not; CR LF, byte-order mark, relative or missing interpreter, line over 512 bytes, Linux not splitting arguments, not marked executable; the text with line numbers (first 512 KB)
- [x] **Text with the execute bit**: shown as text, with a note that it is marked executable
- [x] Script verdicts: "On this Mac" runs (with what) / does not run (why) / runs only some way; "On Linux" when it differs
- [x] **Windows PE** (`MZ` … `PE\0\0`): kind (console, windowed, DLL, driver, UEFI, .NET), processor, PE32/PE32+, subsystem, minimum Windows, version resource strings, manifest execution level, ASLR/DEP/CFG, linker and time stamp (not a hash from reproducible builds), PDB path, imports (and delay-loaded), exports, sections
- [x] Authenticode: certificate chain, signing time (signed attribute, counter-signature or RFC 3161 token), PE image hash checked
- [x] MS-DOS, 16-bit Windows (NE), OS/2 / VxD (LE, LX) named
- [x] **ar archives** (`.lib`, `.a`): Windows import library and its DLLs, static library, members and their processors (COFF, ELF, Mach-O), symbol count; COFF `.obj` by its header
- [x] **Batch files** (`.bat`, `.cmd`): byte-order mark, UTF-16, LF line endings with labels, non-ASCII without `chcp 65001`; the text
- [ ] Not done: Authenticode's own CMS signature and trust; .NET metadata (types, references); MSI installers; `.ps1`

Code: `Diptych/Support/BinaryReader.swift`, `MachOFile.swift`, `ELF.swift`,
`PEFile.swift`, `ArArchive.swift`, `Script.swift` (scripts and batch files),
`ExecutableReport.swift`; dispatch in `QuickLook.swift`. Samples:
`make-executable-samples.sh`, Windows signatures by `sign-pe-sample.py`.
Tests: `DiptychTests/ExecutableReportTests.swift` (40) with fixtures from
`make-executable-samples.sh` in `ExecutableFixtures.swift`. Swept: 3,521
Mach-O files in the system folders and Homebrew read without error and every
signature matched; 2,116 Windows programs and DLLs (2,072 .NET) and 1,538
libraries read without error, all 650 Authenticode hashes matched.

## 6. `.app` bundles

Also `.appex`, `.xpc`, `.framework`, `.bundle`, `.plugin`, `.kext`,
`.systemextension`, `.saver`, `.prefPane`, `.qlgenerator`, `.mdimporter`,
Audio Units and VST plug-ins. Other packages (`.rtfd`, `.photoslibrary`, …)
still show their icon. A page at once from the Info.plist and the
signature; the seal check and the size follow, and the page reloads.

- [x] Icon, name, version, build, bundle identifier, category, copyright (from `Info.plist`); kind (app, menu bar app, background app, iPhone/iPad app, extension and what it extends, …)
- [x] Main executable: architectures, minimum macOS, Xcode and SDK it was built with (as Mach-O above, with its warnings)
- [x] Code signature: signer and chain, Team ID, hardened runtime, sandbox, entitlements; notarization ticket stapled or not (offline)
- [x] The seal: Info.plist and `CodeResources` against the signature, every sealed file's hash, nested code by cdhash, symlinks; changed and missing files listed (up to 1 GB of sealed files)
- [x] Permissions it will ask for, with its own reasons (`NS…UsageDescription`)
- [x] Documents and URL schemes it opens; languages
- [x] Embedded: frameworks, plug-ins and extensions, login items, privileged helpers, system extensions, XPC services, launch agents and daemons, other programs; each with version, identifier and signing team
- [x] Made with: Electron, Chromium Embedded, Qt, Flutter, Python, Java, Mono, Sparkle, Mac Catalyst
- [x] Size on disk and file count
- [x] Where it came from: Mac App Store receipt, quarantine (agent, date, opened or not), download address; App Translocation
- [ ] Not done: files added after signing (needs the seal's rules), the requirement text, notarization online

Code: `Diptych/Support/AppBundle.swift`, `BundleReport.swift`; dispatch and
icon in `QuickLook.swift`. Tests: `DiptychTests/BundleReportTests.swift`,
bundles built from the executable fixtures and signed ad hoc with
`codesign`, and Calculator as Apple signed it. Samples:
`make-bundle-samples.sh` writes `../test_folder/20-bundles`.

## 7. SQLite databases

Recognised by: `SQLite format 3\0` header (many app databases have other extensions).

**Not an HTML report.** A database is to be looked through, not read once:
more rows fetched as you scroll, sorted and filtered, a long value opened in
full. A static page cannot do that, so the work is in a **Database window**
of its own, native, opened like Text Edit or Compare. Quick Look keeps a
short static summary and a way into the window.

Quick Look (HTML, like the other reports):

- [ ] Tables, views, indexes, triggers, with their schema
- [ ] Row count per table (a very large table: counted up to a cap, said so)
- [ ] A few rows of each table, long values shortened, blobs as their size
- [ ] Encrypted, or not a database after all: said plainly
- [ ] Opens the Database window

Database window (native):

- [ ] The tables and views in a sidebar, the schema of each on request
- [ ] Rows fetched a page at a time as you scroll, never the whole table at once
- [ ] Sort by a column, filter the rows (by column value, or a `WHERE` typed in)
- [ ] A cell's whole value: long text, JSON in it formatted, a blob as hex and size, a picture shown
- [ ] Copy cells, rows, a table as CSV
- [ ] Optional: a `SELECT` of your own, run on the read-only connection (`PRAGMA query_only`)

Rules for both:

- [ ] Read-only, always: `SQLITE_OPEN_READONLY`; nothing is ever written to the file
- [ ] A database another app is using (Mail, Photos, Safari): read without
      disturbing it. Open question: `immutable=1` never touches `-wal`/`-shm`
      but misses what is still in the WAL; a read-only open sees it but needs
      the `-shm`. Possibly a snapshot copy of the three files, read instead.

## 8. Installer packages `.pkg`

Recognised by: xar magic `78 61 72 21` (flat packages), or bundle packages.

- [x] Title, identifier, version, signature and notarization (RSA signature over the table's checksum verified; CMS signing time; stapled ticket)
- [x] Components and where each installs
- [x] Files installed (from the Bom), totals; launch daemons, helpers, extensions and setuid files called out
- [x] Pre- and post-install scripts, shown in full — the safety question before installing
- [x] Distribution: requirements, choices, Installer JavaScript, restart afterwards
- [x] Old bundle packages (folders)
- [ ] Not done: the certificate chain's trust; bzip2-encoded xar entries; the payload itself

## 9. Disk images `.dmg`

- [x] Format (UDZO, UDBZ, ULFO, ULMO, UDRO, raw, sparse, sparse bundle, ASIF), compressed and full size
- [x] Encrypted or not
- [x] Code signature and notarization of the image (whole-image hash and trailer checked, in the background)
- [x] Partition scheme (GPT, Apple, MBR); APFS and HFS+ volume name, counts and top-level items; FAT, exFAT, NTFS, ISO 9660 named
- [x] No mounting
- [x] License agreement text
- [ ] Not done: bzip2 and ADC chunks (named, not read); ASIF contents; the CRC32 checksum; old NDIF images

## 10. Crash reports `.ips`

Recognised by: a JSON header line followed by a JSON body.

- [x] Process, version, OS, hardware, date
- [x] Exception type, codes, termination reason
- [x] Crashed thread's stack, readable; other threads collapsed
- [x] Binary images list (collapsed)
- [x] What happened in words (Swift runtime failures, bad access, abort, guard, killed by the system), the program's own frames picked out, the last exception backtrace
- [ ] Not done: reports that are not crashes (hangs, low memory) are shown as their JSON or text, not laid out

## 11. `.mobileprovision`

Recognised by: CMS-signed plist.

- [x] Name, app identifier, team, creation and expiry (expired highlighted)
- [x] Entitlements
- [x] Devices (count, list collapsed), or "all devices" / App Store
- [x] Developer certificates: subject and expiry
- [x] Kind: development, ad hoc, App Store, Developer ID, in-house
- [x] Signature checked with the system's CMS decoder; the chain evaluated without the network, as of the signing time

## 12. `.webloc` `.inetloc` `.url`

- [x] The target URL, clickable (ordinary web addresses only)
- [x] `.url` (Windows INI form) parsed as well as the plist forms
- [x] The app that opens it; the address taken apart, tracking parameters named
- [x] Warnings: user name before "@", punycode site names, programs at the end, files on other computers, remote icons
- [x] `.fileloc`, `.ftploc`, `.afploc`; old locations kept only in the resource fork

## 13. Syntax-formatted text

JSON, YAML and TOML are a small part of a large family: every file whose
reading is helped by colouring its syntax -- data formats (JSON, `.jsonl`,
YAML, TOML, XML), markup and styles (HTML, CSS, Markdown source), the popular
programming languages, shell, SQL, build and configuration files. They are
one problem, solved once, not one format after another.

**Engine: TextMate grammars.** The grammar files VS Code and many other
editors use (`.tmLanguage`, JSON or plist): the widest language coverage
there is, and maintained by each language's own community. One engine for
both places a file is read:

- Quick Look: a static HTML page, the text with coloured spans
- Text Edit: the same scopes, drawn as temporary attributes, as
  `SyntaxColouring` draws its colours today -- which it then replaces

Design questions, the first task of this item:

- [ ] The regular expressions: grammars are written for Oniguruma, which
      `NSRegularExpression` (ICU) matches closely but not exactly (`\G`,
      some look-behinds, `\h`, possessive forms). Bundle Oniguruma, or
      translate and accept the few grammars that break
- [ ] Which grammars ship, from where, under which licence (VS Code's are
      MIT; check each); kept up to date how
- [ ] Which language a file is: extension, then `#!` line, modelines, the
      file's type; a choice in Text Edit when it guesses wrong
- [ ] Scopes to colours: one theme, light and dark, matched to what Text Edit
      already uses
- [ ] Speed: a size cap for Quick Look ("first N KB shown"); Text Edit
      colouring as you type, off the main thread, only what changed

What colouring cannot give -- TextMate grammars know tokens, not structure
-- the data formats keep from parsers of their own:

- [ ] JSON, YAML, TOML: a formatted, collapsible tree
- [ ] A syntax error: line, column and the text around it
- [ ] `.jsonl`: one entry per line, counted
- [ ] Brackets and tags that belong together (Text Edit's pairs, kept)

## 14. Git repository folders

In the existing folder report.

- [ ] Branch, upstream, ahead/behind
- [ ] Uncommitted changes (count, list collapsed)
- [ ] Last few commits
- [ ] Reuse what `git-integration.md` already describes

## 15. `.properties`

- [x] Keys and values as a table
- [x] `\uXXXX` escapes decoded, line continuations joined
- [x] Comments kept
- [x] Keys set twice marked, invisible blanks and escaped line breaks shown, broken `\u` escapes pointed out
- [x] UTF-8 or ISO 8859-1, said which; the locale of a resource bundle named

## 16. `.eml` / `.mbox`

- [x] `.eml`: headers (From, To, Date, Subject), body as text, attachments listed with sizes
- [x] `.mbox`: one row per message, opened from the list (the first 300 open in place)
- [x] `.emlx`, Mail's exported `.mbox` folders, forwarded messages, pictures shown
- [x] Warnings: SPF/DKIM/DMARC failures, Reply-To elsewhere, misleading links, attachments that run code
- [x] S/MIME and OpenPGP signed or encrypted, named (signatures not verified)

## 17. Where it came from (any file)

Moved: not a format but something every file has, so it belongs to all of
them at once. See `where-it-came-from.md`.

---

## Log

Newest first. One line per change: date, format #, what was done.

| Date | # | Done |
|------|---|------|
| 2026-11-15 | 7, 13, 17 | Replanned: SQLite gets a native Database window, Quick Look only a summary; JSON/YAML/TOML widened to all syntax-formatted text on TextMate grammars, shared with Text Edit; "where it came from" moved to `where-it-came-from.md` |
| 2026-11-14 | 10, 11, 12, 15 | Crash reports, provisioning profiles (CMS signature and chain checked), web locations and Windows shortcuts (with warnings, resource-fork locations, punycode), Java properties; `make-small-samples.sh`; 9 tests with damaged-file rounds |
| 2026-11-14 | 8, 9, 16 | Installer packages (xar, Bom, scripts, signature check), disk images (UDIF chunks, GPT/APM/MBR, HFS+ and APFS listing, signature check), e-mail and mailboxes; three sample scripts; 32 tests with damaged-file rounds |
| 2026-11-14 | 6 | Bundle preview: Info.plist, signature, seal checked file by file, permissions, embedded code, origin; `make-bundle-samples.sh` |
| 2026-11-14 | 5 | Windows PE with Authenticode check, ar libraries, COFF objects, batch files; script verdicts per system; Text Edit shows invisible characters, BOM kept in the text; 13 + 9 tests |
| 2026-11-14 | 5 | Mach-O (signature checked page by page), ELF, scripts and executable text; 27 tests; `make-executable-samples.sh` |
| 2026-11-13 | 4 | Certificates, requests, CRLs, keys and SSH keys; chain and key matching; 23 tests; `make-certificate-samples.sh` |
| 2026-11-13 | 3 | Key store preview: JKS, JCEKS, PKCS#12 with default-password check; 13 tests; `make-java-samples.sh` |
| 2026-11-13 | 2 | `.ear` gets the archive listing and Extract, like `.jar` and `.war` |
| 2026-11-13 | 1 | Java `.class` preview: reader, generic signatures, page, 18 tests |
| 2026-11-13 | — | Document started |
