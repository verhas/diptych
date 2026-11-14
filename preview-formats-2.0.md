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
| 2 | `.jar` / `.war` / `.ear` header | 1 | planned | | `.ear` now gets the archive listing too |
| 3 | Key stores `.jks` `.jceks` `.keystore` `.ks` `.truststore` `.p12` `.pfx` | 1 | done | 2.0.0 | `KeyStore`, `PKCS12`, `X509`, `DER`, `KeyStoreReport` |
| 4 | Certificates and keys `.cer` `.crt` `.pem` `.der` `.csr` `.crl` `.p7b`, SSH keys | 1 | done | 2.0.0 | `CertificateFile`, `SSHKey`, `CertificateReport` |
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
| 2026-11-13 | 4 | Certificates, requests, CRLs, keys and SSH keys; chain and key matching; 23 tests; `make-certificate-samples.sh` |
| 2026-11-13 | 3 | Key store preview: JKS, JCEKS, PKCS#12 with default-password check; 13 tests; `make-java-samples.sh` |
| 2026-11-13 | 2 | `.ear` gets the archive listing and Extract, like `.jar` and `.war` |
| 2026-11-13 | 1 | Java `.class` preview: reader, generic signatures, page, 18 tests |
| 2026-11-13 | — | Document started |
