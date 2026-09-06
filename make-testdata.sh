#!/bin/bash
#
# Wipes ./test and rebuilds a playground for exercising Diptych by hand:
# deep nesting, awkward names, symlinks, hidden files, executables, packages,
# and one directory big enough to need scrolling.
#
# Safe by construction: it only ever touches ./test next to this script.

set -euo pipefail
cd "$(dirname "$0")"

ROOT="$PWD/test"

# Refuse to run anywhere unexpected -- this script deletes a directory tree.
case "$ROOT" in
    */file-manager/test) ;;
    *) echo "refusing to wipe '$ROOT'" >&2; exit 1 ;;
esac

echo "==> Rebuilding $ROOT"
# Strip access control lists first. The fixture deliberately contains a file
# whose ACL denies delete, and rm cannot remove it while that stands -- which
# left the tree half-wiped and the script dead on `set -e`.
[ -d "$ROOT" ] && chmod -R -N "$ROOT" 2>/dev/null
rm -rf "$ROOT"
mkdir -p "$ROOT"
cd "$ROOT"

# ---------------------------------------------------------------- deep nesting
mkdir -p projects/alpha/src/main/swift/models
mkdir -p projects/alpha/src/main/swift/views
mkdir -p projects/alpha/src/test/fixtures/golden
mkdir -p projects/beta/vendor/third-party/lib/include/detail
mkdir -p projects/gamma/docs/design/2026/q1
mkdir -p "projects/delta/a/b/c/d/e/f/g/h"

echo "// deepest file in the tree" > projects/delta/a/b/c/d/e/f/g/h/bottom.swift

for f in Account Session Ledger; do
    printf 'struct %s {\n    let id: UUID\n}\n' "$f" > "projects/alpha/src/main/swift/models/$f.swift"
done
printf 'import SwiftUI\nstruct RootView: View { var body: some View { Text("hi") } }\n' \
    > projects/alpha/src/main/swift/views/RootView.swift
printf '{\n  "expected": [1, 2, 3]\n}\n' > projects/alpha/src/test/fixtures/golden/case-01.json

# --------------------------------------------------------------- awkward names
mkdir -p "awkward names"
cd "awkward names"
touch "file with spaces.txt"
touch "double  space.txt"
touch "tab	character.txt"
touch "quote'apostrophe.txt"
touch 'dollar$sign.txt'
touch "unicode-ü-ñ-日本語.txt"
touch "emoji-🎛️-name.txt"
touch -- "-leading-dash.txt"   # -- so touch does not read it as flags
touch "trailing.dots..."
touch "a-very-long-file-name-that-should-be-truncated-somewhere-in-the-column-because-it-just-keeps-going.txt"
touch "no-extension"
cd ..

# ------------------------------------------------------------------ file types
mkdir -p assets
printf 'Plain text.\nSecond line.\n' > assets/notes.txt
printf '# Heading\n\nSome **markdown** for Quick Look.\n' > assets/readme.md
printf '{\n  "name": "diptych",\n  "panes": 2\n}\n' > assets/config.json
printf 'name,size,modified\nalpha,120,2026-01-01\nbeta,4096,2026-02-14\n' > assets/data.csv
printf '<?xml version="1.0"?>\n<root><item id="1"/></root>\n' > assets/feed.xml

# A real PNG and a real PDF, so Quick Look has something to render.
python3 - <<'PYEOF'
import zlib, struct
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
w = h = 128
rows = b""
for y in range(h):
    rows += b"\x00" + bytes([(x * 2) % 256 if (x // 16 + y // 16) % 2 else 40 for x in range(w) for _ in (0,)][:w] * 3)
raw = b""
for y in range(h):
    raw += b"\x00"
    for x in range(w):
        on = (x // 16 + y // 16) % 2
        raw += bytes((240, 90, 60) if on else (40, 50, 90))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
open("assets/checkerboard.png", "wb").write(png)
PYEOF

cat > assets/onepage.pdf <<'PDFEOF'
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 120] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
4 0 obj << /Length 62 >>
stream
BT /F1 18 Tf 20 60 Td (Diptych test page) Tj ET
endstream
endobj
5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
trailer << /Root 1 0 R >>
PDFEOF

# ----------------------------------------------------------------- executables
mkdir -p bin
printf '#!/bin/bash\necho "hello from script"\n' > bin/greet.sh
printf '#!/usr/bin/env python3\nprint("hello from python")\n' > bin/report.py
printf '#!/bin/bash\necho "no extension, still executable"\n' > bin/runner
chmod +x bin/greet.sh bin/report.py bin/runner
printf '#!/bin/bash\necho "not executable"\n' > bin/inert.sh   # same extension, no +x

# --------------------------------------------------------------- hidden things
printf 'HIDDEN=1\n' > .env
printf '[core]\n\tbare = false\n' > .gitconfig
mkdir -p .cache/objects
touch .cache/objects/deadbeef

# -------------------------------------------------------------------- symlinks
mkdir -p links
ln -s ../projects/alpha links/alpha-project        # -> directory
ln -s ../assets/notes.txt links/notes-alias        # -> file
ln -s /nowhere/at/all links/broken-link            # -> nothing

# -------------------------------------------------------------------- packages
# A bundle: a directory macOS shows as a single item.
mkdir -p "packages/Sample.rtfd"
printf '{\\rtf1\\ansi Hello from a bundle.}' > "packages/Sample.rtfd/TXT.rtf"

# ------------------------------------------------- access control lists + xattrs
mkdir -p acl
printf 'This file carries an access control list.\n' > acl/with-acl.txt
printf 'This folder carries an access control list.\n' > acl/readme.txt
chmod +a "$(whoami) allow read,write,delete" acl/with-acl.txt

# A deliberately locked file, named so it is obvious. An ACL "deny" beats the
# permission bits, and entries are matched top to bottom with the first match
# winning -- so a deny above an allow wins even for the owner. "delete" covers
# renaming too, because a rename removes the old directory entry.
printf 'An ACL denies delete on this file, so it cannot be renamed or removed.\n' \
    > acl/locked-by-acl.txt
chmod +a "$(whoami) allow read,write" acl/locked-by-acl.txt
chmod +a "everyone deny delete" acl/locked-by-acl.txt
mkdir -p acl/protected
chmod +a "$(whoami) allow list,search,add_file,delete_child" acl/protected

# Extended attributes, for the Attributes tab.
xattr -w com.example.note "an editable text attribute" acl/with-acl.txt
xattr -w com.example.reviewer "peter" acl/with-acl.txt

# ------------------------------------------------------------- an empty folder
mkdir -p empty-folder

# ------------------------------------------- a big directory, for scroll tests
mkdir -p many
for i in $(seq -w 1 240); do
    printf 'record %s\n' "$i" > "many/item-$i.log"
done

# ------------------------------------------------- a few differently sized files
mkdir -p sizes
head -c 1        /dev/zero > sizes/1-byte.bin
head -c 1024     /dev/zero > sizes/1-kb.bin
head -c 1048576  /dev/urandom > sizes/1-mb.bin
head -c 10485760 /dev/urandom > sizes/10-mb.bin

echo "==> ACLs:"
/bin/ls -le acl/with-acl.txt | sed 's/^/    /'

echo "==> Done."
find "$ROOT" -mindepth 1 -maxdepth 1 | sort | sed 's|.*/|    |'
echo "    ($(find "$ROOT" -type f | wc -l | tr -d ' ') files, $(find "$ROOT" -type d | wc -l | tr -d ' ') directories)"
