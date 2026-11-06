#!/bin/bash
#
# Makes Diptych/Licenses.json: the licence of every package built into
# Diptych, read from the checkouts Xcode resolved, for the Acknowledgements
# window. Run again whenever Package.resolved changes; build.sh does it then,
# and a test fails when the file and Package.resolved disagree.

set -euo pipefail
cd "$(dirname "$0")"

RESOLVED="Diptych.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
OUT="Diptych/Licenses.json"

# Where Xcode checks the packages out: next to the build products.
build_dir=$(xcodebuild -project Diptych.xcodeproj -scheme Diptych -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ BUILD_DIR =/{print $2; exit}')
[ -n "$build_dir" ] || { echo "could not find the build folder" >&2; exit 1; }
checkouts="$(dirname "$(dirname "$build_dir")")/SourcePackages/checkouts"
if [ ! -d "$checkouts" ]; then
    xcodebuild -resolvePackageDependencies -project Diptych.xcodeproj -scheme Diptych >/dev/null 2>&1
fi
[ -d "$checkouts" ] || { echo "no package checkouts in $checkouts" >&2; exit 1; }

python3 - "$RESOLVED" "$checkouts" "$OUT" <<'PY'
import json, os, re, sys

resolved, checkouts, out = sys.argv[1:]

# Resolved, but only used while building -- SwiftTerm's build plugin -- and
# not in the app: nothing of it ships.
BUILD_ONLY = {"swift-argument-parser"}

NAMES = {
    "bigint": "BigInt", "citadel": "Citadel", "eventsource": "EventSource",
    "libwebp-xcode": "libwebp", "swift-asn1": "SwiftASN1", "swift-atomics": "Swift Atomics",
    "swift-collections": "Swift Collections", "swift-crypto": "Swift Crypto",
    "swift-log": "SwiftLog", "swift-nio": "SwiftNIO", "swift-nio-ssh": "SwiftNIO SSH",
    "swift-sdk": "MCP Swift SDK", "swift-system": "Swift System", "swiftterm": "SwiftTerm",
}
USE = {
    "bigint": "Arbitrary-precision arithmetic, for SSH keys",
    "citadel": "SSH and SFTP client",
    "eventsource": "Server-sent events, for the MCP server",
    "libwebp-xcode": "Writing WebP images",
    "swift-asn1": "ASN.1 and DER, for keys and certificates",
    "swift-atomics": "Atomic operations, for SwiftNIO",
    "swift-collections": "Data structures, for SwiftNIO",
    "swift-crypto": "Cryptography, including BoringSSL, for SSH",
    "swift-log": "Logging, for SwiftNIO and the MCP SDK",
    "swift-nio": "Networking: the MCP server and SSH",
    "swift-nio-ssh": "The SSH protocol, for SFTP",
    "swift-sdk": "The Model Context Protocol server",
    "swift-system": "System calls, for the MCP SDK",
    "swiftterm": "The terminal panel",
}
# What a package bundles under a licence of its own, beside its top-level one.
EXTRA = {
    "libwebp-xcode": ["libwebp/COPYING", "libwebp/PATENTS"],
    "swift-nio": ["Sources/CNIOLLHTTP/LICENSE"],
}

def kind(text):
    if "Apache License" in text and "Version 2.0" in text: return "Apache 2.0"
    if "Permission is hereby granted, free of charge" in text: return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD 3-Clause" if "Neither the name" in text else "BSD 2-Clause"
    if "Mozilla Public License" in text: return "MPL 2.0"
    return "See the text"

dirs = {d.lower(): d for d in os.listdir(checkouts)}
packages = []
for pin in json.load(open(resolved))["pins"]:
    identity = pin["identity"]
    if identity in BUILD_ONLY: continue
    repo = re.sub(r"\.git$", "", pin["location"].rstrip("/").split("/")[-1]).lower()
    folder = os.path.join(checkouts, dirs.get(repo) or dirs.get(identity) or repo)
    if not os.path.isdir(folder): sys.exit(f"no checkout of {identity} in {checkouts}")
    files = sorted(f for f in os.listdir(folder)
                   if re.match(r"(?i)^(licen[cs]e|copying|notice)(\.(txt|md))?$", f))
    files.sort(key=lambda f: 0 if re.match(r"(?i)licen|copying", f) else 1)
    texts = []
    for name in files + EXTRA.get(identity, []):
        path = os.path.join(folder, name)
        if not os.path.isfile(path): sys.exit(f"{identity}: no {name}")
        text = open(path, encoding="utf-8", errors="replace").read().strip()
        if text not in [t for _, t in texts]: texts.append((name, text))
    if not texts: sys.exit(f"{identity}: no licence file found")
    packages.append({
        "id": identity,
        "name": NAMES.get(identity, identity),
        "use": USE.get(identity, ""),
        "version": pin["state"].get("version") or pin["state"].get("revision", "")[:12],
        "url": re.sub(r"\.git$", "", pin["location"]),
        "license": kind(texts[0][1]),
        "files": [{"name": n, "text": t} for n, t in texts],
    })

packages.sort(key=lambda p: p["name"].lower())
with open(out, "w", encoding="utf-8") as f:
    json.dump(packages, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"{out}: {len(packages)} packages")
for p in packages: print(f"  {p['name']} {p['version']} -- {p['license']}")
PY
