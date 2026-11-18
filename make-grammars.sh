#!/bin/bash
#
# Fetches the TextMate grammars Diptych colours source text with -- Quick
# Look's pages and Text Edit alike -- from Visual Studio Code's built-in
# extensions, at the release pinned below, into Diptych/Grammars:
#
#   <scope>.json     each grammar, as VS Code ships it, minified
#   Grammars.json    the languages (file extensions, file names, first
#                    lines), which grammar each uses, the languages a grammar
#                    embeds, and where every grammar came from, under which
#                    licence -- for the Acknowledgements window
#
# Run again to move to a newer release: change VSCODE below. Needs the
# network and python3. Nothing outside Diptych/Grammars is written.

set -euo pipefail
cd "$(dirname "$0")"
VSCODE="1.146.0"
OUT="Diptych/Grammars"
mkdir -p "$OUT"

python3 - "$VSCODE" "$OUT" <<'PY'
import json, os, re, sys, urllib.parse, urllib.request

tag, out = sys.argv[1:]
raw = f"https://raw.githubusercontent.com/microsoft/vscode/{tag}/"

def fetch(path):
    with urllib.request.urlopen(raw + urllib.parse.quote(path), timeout=60) as response:
        return response.read()

def loose_json(data):
    # package.json and cgmanifest.json are JSON; some grammar files carry
    # comments, which json does not allow.
    text = data.decode("utf-8")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
        return json.loads(text)

tree = json.loads(urllib.request.urlopen(
    f"https://api.github.com/repos/microsoft/vscode/git/trees/{tag}?recursive=1", timeout=60).read())
extensions = sorted({t["path"].split("/")[1] for t in tree["tree"]
                     if t["path"].startswith("extensions/") and t["path"].endswith("/package.json")
                     and t["path"].count("/") == 2})

# Not wanted: GPU C++, VS Code's snippet files, and the latex grammar's
# private copy of C++.
SKIP = {"source.cuda-cpp", "source.json.comments.snippets", "source.cpp.embedded.latex", "source.cpp.embedded.macro"}

languages, grammars, licences = [], [], {}
for name in extensions:
    try:
        package = loose_json(fetch(f"extensions/{name}/package.json"))
    except Exception:
        continue
    contributes = package.get("contributes", {})
    found = [g for g in contributes.get("grammars", []) if "scopeName" in g and "path" in g]
    if not found:
        continue
    try:
        manifest = loose_json(fetch(f"extensions/{name}/cgmanifest.json"))
    except Exception:
        manifest = {"registrations": []}
    sources = []
    for registration in manifest.get("registrations", []):
        component = registration.get("component", {})
        git = component.get("git", {})
        sources.append({
            "name": git.get("name") or component.get("other", {}).get("name") or name,
            "url": git.get("repositoryUrl") or component.get("other", {}).get("downloadUrl", ""),
            "commit": git.get("commitHash", ""),
            "license": registration.get("license", ""),
            "licenseDetail": "\n".join(line if isinstance(line, str) else "\n".join(line)
                                       for line in registration.get("licenseDetail", [])),
            "version": registration.get("version", ""),
        })
    licences[name] = sources

    for language in contributes.get("languages", []):
        if "id" not in language:
            continue
        languages.append({
            "id": language["id"],
            "names": language.get("aliases", [])[:1] or [language["id"]],
            "extensions": [e.lstrip(".").lower() for e in language.get("extensions", [])],
            "filenames": language.get("filenames", []),
            "firstLine": language.get("firstLine"),
            "extension": name,
        })
    for grammar in found:
        scope = grammar["scopeName"]
        if scope in SKIP or grammar.get("injectTo"):
            continue
        path = os.path.normpath(os.path.join("extensions", name, grammar["path"]))
        try:
            content = loose_json(fetch(path))
        except Exception as error:
            print(f"  skipped {scope}: {error}", file=sys.stderr)
            continue
        with open(os.path.join(out, scope + ".json"), "w", encoding="utf-8") as f:
            json.dump(content, f, separators=(",", ":"), ensure_ascii=False)
        grammars.append({
            "scope": scope,
            "language": grammar.get("language"),
            "embedded": grammar.get("embeddedLanguages", {}),
            "extension": name,
        })

# A language without a grammar of its own colours nothing: left out. So are
# VS Code's own -- chat agents, prompts, search results -- and the grammars
# only other grammars use.
VSCODE_ONLY = {"chatagent", "instructions", "prompt", "skill", "search-result",
               "markdown_latex_combined", "markdown-math"}
coloured = {g["language"] for g in grammars if g["language"]}
languages = [l for l in languages if l["id"] in coloured and l["id"] not in VSCODE_ONLY]
# Several extensions may describe one language: their extensions merged.
merged = {}
for language in languages:
    known = merged.setdefault(language["id"], {**language, "extensions": [], "filenames": []})
    for key in ("extensions", "filenames"):
        known[key] += [v for v in language[key] if v not in known[key]]
    known["firstLine"] = known["firstLine"] or language["firstLine"]
used = sorted({g["extension"] for g in grammars})

# Each grammar's licence in full, from VS Code's third-party notices: the
# registrations above mostly name a licence without its text.
def key(url):
    return re.sub(r"(\.git)?/*$", "", url.strip().lower()).replace("http://", "https://")
notices = {}
for section in fetch("ThirdPartyNotices.txt").decode("utf-8").split("-" * 57):
    lines = section.strip().splitlines()
    if len(lines) > 2 and lines[1].startswith("http"):
        notices[key(lines[1])] = section.strip()
missing = []
for name in used:
    for source in licences.get(name, []):
        notice = notices.get(key(source["url"])) if source["url"] else None
        source["notice"] = notice or source["licenseDetail"]
        if not source["notice"]:
            missing.append(source["name"])
if missing:
    print("  no licence text found for: " + ", ".join(sorted(set(missing))), file=sys.stderr)
with open(os.path.join(out, "Grammars.json"), "w", encoding="utf-8") as f:
    json.dump({"vscode": tag,
               "vscodeLicense": fetch("LICENSE.txt").decode("utf-8"),
               "languages": sorted(merged.values(), key=lambda l: l["id"]),
               "grammars": sorted(grammars, key=lambda g: g["scope"]),
               "sources": {name: licences.get(name, []) for name in used}},
              f, indent=1, ensure_ascii=False)
    f.write("\n")
size = sum(os.path.getsize(os.path.join(out, n)) for n in os.listdir(out))
print(f"{out}: {len(grammars)} grammars, {len(merged)} languages, {size // 1024} KB, from VS Code {tag}")
PY
