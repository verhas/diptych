#!/bin/sh
# name: Explain with an Agent
# description: An AI agent reads each selected PDF and writes an HTML report beside it, of the same name: a summary, an explanation, and links to related documents in the folder.
# apply-to: name = "*.pdf", name = "*.PDF"
# args: 1,
# call: $0 $@
# source: diptych
# version: 1
set -eu

# Which agent: the first of these that is installed -- the one named in
# Settings > Agents first, when it is one of them. DIPTYCH_REPORT_AGENT picks
# one outright. Each is started headless, in the agent terminal's folder, so
# the MCP servers, skills and instructions it has there apply here too.
known_agents="claude codex copilot gemini cursor-agent"

# The look of every report: written here the first time, from the copies at
# the start of this script, and used as they are from then on -- edit them to
# change how all later reports look.
templates="$HOME/.diptych/templates/pdf-report"

# The language the report is written in, whatever the document's own:
# English, unless DIPTYCH_REPORT_LANGUAGE names another.
language="${DIPTYCH_REPORT_LANGUAGE:-English}"

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# -- The person's own PATH ---------------------------------------------------
# Diptych starts scripts with the PATH macOS gives an app, which leaves out
# ~/.local/bin and Homebrew, where agents are installed. The login shell's
# is the one the terminal has.
login_path=$("${SHELL:-/bin/zsh}" -lc 'printf %s "$PATH"' </dev/null 2>/dev/null || true)
PATH="${login_path:+$login_path:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

# -- Where the agent terminal starts, and which agent it runs ---------------
config="$HOME/.diptych/config.json"
setting() {
    [ -f "$config" ] && /usr/bin/plutil -extract "$1" raw -o - "$config" 2>/dev/null || true
}
agent_dir=$(setting agentDirectory)
[ -n "$agent_dir" ] || agent_dir="~/.diptych/agentic"
case "$agent_dir" in
    "~") agent_dir="$HOME" ;;
    "~/"*) agent_dir="$HOME/${agent_dir#"~/"}" ;;
esac
[ -d "$agent_dir" ] || fail "the agent folder $agent_dir does not exist yet. Open the agent terminal once (View > Show Agent Terminal) so Diptych sets it up."

configured=$(setting agentCommand)
configured=${configured%% *}
configured=${configured##*/}

agent=""
if [ -n "${DIPTYCH_REPORT_AGENT:-}" ]; then
    command -v "$DIPTYCH_REPORT_AGENT" >/dev/null 2>&1 \
        || fail "DIPTYCH_REPORT_AGENT is $DIPTYCH_REPORT_AGENT, which is not installed."
    agent=$DIPTYCH_REPORT_AGENT
else
    for candidate in $configured $known_agents; do
        case " $known_agents " in *" $candidate "*) ;; *) continue ;; esac
        if command -v "$candidate" >/dev/null 2>&1; then agent=$candidate; break; fi
    done
fi
[ -n "$agent" ] || fail "none of these agents is installed: $known_agents."
say "Agent: $agent ($(command -v "$agent")), started in $agent_dir"

# -- The template and the stylesheet ----------------------------------------
# [[...]] is for the agent to fill in; {{...}} is filled in here, before the
# agent sees it.
write_template() {
    cat <<'TEMPLATE'
<!DOCTYPE html>
<html lang="[[two-letter language code of the report, such as en]]">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="Diptych: Explain with an Agent ({{AGENT}})">
<title>[[The document's title, or what it is]] -- report</title>
<!-- REPORT-CSS -->
</head>
<body>
<main class="report">

<header class="masthead">
  <p class="eyebrow">Document report</p>
  <h1>[[The document's title, or a short name for what it is]]</h1>
  <p class="subtitle">[[One line: what kind of document, from whom, to whom, dated when]]</p>
  <dl class="facts">
    <div><dt>Source</dt><dd><a href="{{SOURCE_HREF}}">{{SOURCE_NAME}}</a></dd></div>
    <div><dt>Pages</dt><dd>{{PAGES}}</dd></div>
    <div><dt>Written</dt><dd>{{GENERATED}}</dd></div>
    <div><dt>By</dt><dd>{{AGENT}}</dd></div>
  </dl>
</header>

<section class="glance">
  <h2>At a glance</h2>
  <p>[[Two to four plain sentences: what this is and what it means for the reader]]</p>
</section>

<section class="points">
  <h2>Key points</h2>
  <ul>
    <li><strong>[[A fact, figure, date or decision]]</strong> [[a few words of context]]</li>
    <li><strong>[[Another]]</strong> [[context]]</li>
  </ul>
</section>

<section class="explained">
  <h2>Explained</h2>
  <article>
    <h3>[[A part of the document]]</h3>
    <p>[[What it says, in plain language, and why it matters]]</p>
  </article>
  <article>
    <h3>[[The next part]]</h3>
    <p>[[...]]</p>
  </article>
</section>

<section class="terms">
  <h2>Terms</h2>
  <dl>
    <dt>[[Term]]</dt>
    <dd>[[What it means here]]</dd>
  </dl>
</section>

<section class="checks">
  <h2>Worth checking</h2>
  <ul>
    <li>[[A deadline, an amount, an action asked of the reader, or an open question]]</li>
  </ul>
</section>

<section class="related">
  <h2>Related documents</h2>
  <ul>
    <li><a href="[[percent-encoded file name]]">[[file name]]</a> <span class="why">[[How it is related]]</span></li>
  </ul>
</section>

<footer class="colophon">
  <p>A summary of <a href="{{SOURCE_HREF}}">{{SOURCE_NAME}}</a>, written by an AI agent ({{AGENT}}) on {{GENERATED}}. It can be wrong: the document itself is what counts.</p>
</footer>

</main>
</body>
</html>
TEMPLATE
}

write_css() {
    cat <<'STYLESHEET'
/* Diptych -- Explain with an Agent: the look of every report. */
:root {
  --paper: #fbfaf7;
  --ink: #1f2328;
  --muted: #5d6670;
  --rule: #e3e0d8;
  --accent: #1f5f8b;
  --accent-soft: #e8f0f6;
  --warn: #8a5a00;
  --warn-soft: #fbf3e2;
  --card: #ffffff;
  --serif: "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif;
  --sans: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper: #17191c;
    --ink: #e6e3dc;
    --muted: #9aa3ad;
    --rule: #2f3338;
    --accent: #7fb6dd;
    --accent-soft: #1d2a35;
    --warn: #e0b45c;
    --warn-soft: #2b2416;
    --card: #1e2124;
  }
}
* { box-sizing: border-box; }
html { background: var(--paper); color: var(--ink); }
body {
  margin: 0;
  font: 17px/1.6 var(--serif);
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}
.report { max-width: 44rem; margin: 0 auto; padding: 3.5rem 1.5rem 4rem; }
a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { text-decoration-thickness: 2px; }
h1, h2, h3, .eyebrow, .subtitle, .facts, .colophon, .why { font-family: var(--sans); }

.masthead { border-bottom: 1px solid var(--rule); padding-bottom: 1.5rem; margin-bottom: 2rem; }
.eyebrow {
  margin: 0 0 .5rem; font-size: .75rem; font-weight: 600;
  letter-spacing: .12em; text-transform: uppercase; color: var(--accent);
}
h1 { margin: 0; font-size: 2.1rem; line-height: 1.2; font-weight: 700; letter-spacing: -.01em; }
.subtitle { margin: .6rem 0 0; color: var(--muted); font-size: 1rem; }
.facts {
  display: flex; flex-wrap: wrap; gap: .5rem 2rem;
  margin: 1.25rem 0 0; font-size: .85rem;
}
.facts div { display: flex; gap: .45rem; }
.facts dt { color: var(--muted); }
.facts dd { margin: 0; font-weight: 500; }

section { margin: 2.25rem 0; }
h2 {
  font-size: .8rem; font-weight: 700; letter-spacing: .1em; text-transform: uppercase;
  color: var(--muted); margin: 0 0 .9rem; padding-bottom: .4rem; border-bottom: 1px solid var(--rule);
}
h3 { font-size: 1.1rem; margin: 1.5rem 0 .4rem; }
p { margin: 0 0 .9rem; }

.glance p {
  font-size: 1.2rem; line-height: 1.55; margin: 0;
  padding: 1.1rem 1.3rem; background: var(--accent-soft);
  border-left: 3px solid var(--accent); border-radius: 0 6px 6px 0;
}
.points ul, .checks ul, .related ul { padding-left: 1.2rem; margin: 0; }
.points li, .checks li, .related li { margin: .45rem 0; }
.points strong { font-weight: 650; }
.explained article + article { border-top: 1px dashed var(--rule); }

.terms dl { margin: 0; display: grid; grid-template-columns: max-content 1fr; gap: .5rem 1.25rem; }
.terms dt { font-weight: 650; }
.terms dd { margin: 0; }

.checks ul {
  list-style: none; padding: .9rem 1.2rem; background: var(--warn-soft);
  border-left: 3px solid var(--warn); border-radius: 0 6px 6px 0;
}
.checks li::before { content: "\2192\00a0"; color: var(--warn); font-weight: 700; }

.related .why { display: block; color: var(--muted); font-size: .9rem; }

code { font-family: var(--mono); font-size: .9em; }
table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: .95rem; }
th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { font-family: var(--sans); font-size: .85rem; color: var(--muted); }
blockquote { margin: 1rem 0; padding: 0 1rem; border-left: 3px solid var(--rule); color: var(--muted); }

.colophon {
  margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--rule);
  font-size: .8rem; color: var(--muted);
}

@media (max-width: 600px) {
  body { font-size: 16px; }
  .report { padding: 2rem 1rem 3rem; }
  h1 { font-size: 1.7rem; }
  .terms dl { grid-template-columns: 1fr; }
  .terms dd { margin-bottom: .5rem; }
}
@media print {
  html { background: #fff; color: #000; }
  .report { max-width: none; padding: 0; }
  .glance p, .checks ul { background: none; }
  a { color: inherit; }
  section { break-inside: avoid-page; }
}
STYLESHEET
}

mkdir -p "$templates"
[ -f "$templates/template.html" ] || write_template > "$templates/template.html"
[ -f "$templates/report.css" ] || write_css > "$templates/report.css"

# -- Helpers -----------------------------------------------------------------
# A file name as it goes into a link beside it: percent-encoded.
href() {
    /usr/bin/osascript -l JavaScript -e 'function run(argv) { return encodeURIComponent(argv[0]) }' "$1"
}

# The text of a PDF, for an agent that cannot read PDFs itself. PDFKit, from
# JavaScript for Automation, so nothing has to be installed.
pdf_text() {
    /usr/bin/osascript -l JavaScript -e '
        function run(argv) {
            ObjC.import("PDFKit");
            var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
            if (!doc || doc.isNil()) return "";
            var text = doc.string;
            return (text && !text.isNil()) ? text.js : "";
        }' "$1" 2>/dev/null || true
}

pdf_pages() {
    /usr/bin/osascript -l JavaScript -e '
        function run(argv) {
            ObjC.import("PDFKit");
            var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
            return (!doc || doc.isNil()) ? "?" : String(doc.pageCount);
        }' "$1" 2>/dev/null || printf '?'
}

# Replaces each {{KEY}} in a file with the value of the environment variable
# R_KEY, literally: names with & / \ in them stay as they are.
fill() {
    /usr/bin/awk '
        function put(line, key, value,   at, out) {
            out = ""
            while ((at = index(line, key)) > 0) {
                out = out substr(line, 1, at - 1) value
                line = substr(line, at + length(key))
            }
            return out line
        }
        {
            $0 = put($0, "{{SOURCE_NAME}}", ENVIRON["R_SOURCE_NAME"])
            $0 = put($0, "{{SOURCE_HREF}}", ENVIRON["R_SOURCE_HREF"])
            $0 = put($0, "{{PAGES}}", ENVIRON["R_PAGES"])
            $0 = put($0, "{{GENERATED}}", ENVIRON["R_GENERATED"])
            $0 = put($0, "{{AGENT}}", ENVIRON["R_AGENT"])
            print
        }' "$1"
}

# The stylesheet put into the report where the template marks it, so a
# report is one file that looks the same wherever it is moved or mailed.
inline_css() {
    # sh has no local variables: these names are this function's alone.
    _page=$1 _css=$2
    if grep -q '<!-- REPORT-CSS -->' "$_page"; then
        /usr/bin/awk -v css="$_css" '
            index($0, "<!-- REPORT-CSS -->") {
                print "<style>"
                while ((getline line < css) > 0) print line
                print "</style>"
                next
            }
            { print }' "$_page"
    else
        /usr/bin/awk -v css="$_css" '
            !done && index(tolower($0), "</head>") {
                print "<style>"
                while ((getline line < css) > 0) print line
                print "</style>"
                done = 1
            }
            { print }' "$_page"
    fi
}

# -- The prompt --------------------------------------------------------------
prompt_for() {
    _pdf=$1 _folder=$2 _work=$3 _others=$4
    cat <<PROMPT
You are writing a report about one PDF document, for the person who selected it in Diptych. Work on your own: nobody will answer questions while you run.

THE DOCUMENT
$_pdf

Read it in full -- every page, including tables, figures and small print. If you cannot read PDF files directly, its text has been extracted for you to $_work/text.txt (layout and pictures are lost there, so prefer the PDF where you can).

THE REPORT
Write the whole report in $language -- every heading, sentence and list item -- whatever language the document itself is in. A German, French or Italian document gets a report in $language, not in its own language. Where the original wording matters (names, titles, terms of art, a key sentence), give it in the original once, in quotation marks, followed by its $language meaning. Set the template's lang attribute to the code of $language.
The report has these parts:
1. "At a glance": what this document is and what it means for the reader, in two to four plain sentences.
2. "Key points": the five to ten things that matter most -- facts, figures, dates, amounts, obligations, decisions -- each one short.
3. "Explained": the document explained section by section, in plain language, for someone who is not a specialist. Explain technical terms, legal or financial language and abbreviations where they appear. Say what is unusual or important, not only what is written.
4. "Terms": a short glossary of the terms the reader may not know. Leave the section out if there are none.
5. "Worth checking": deadlines, amounts to pay, actions asked of the reader, inconsistencies or open questions. Leave the section out if there is nothing.
6. "Related documents": see below.
Be accurate: report only what the document says, quote numbers and dates exactly, and say so when something is unclear or missing. Do not invent anything.

RELATED DOCUMENTS
Look at the other files in the same folder, $_folder -- listed at the end -- and open the ones whose names suggest they could be related, to check. Related means: the same subject, case, order, contract, person or project; an earlier or later version; an attachment, reply, invoice, receipt or translation of this one; a report like this one about a related PDF. Link only those that really are related, each with one line saying how. If none are, say so in one sentence.
$_others

THE FORMAT
Use the template $_work/template.html. Keep its structure, its class names and the line <!-- REPORT-CSS --> exactly as they are; the stylesheet is put there afterwards. Replace each placeholder in the form [[...]] with the content it describes, and repeat or remove the example items as needed. Do not add a <style> block, inline styles, scripts or external resources. Links to files in the folder are relative: just the file name, percent-encoded (a space is %20), such as <a href="Invoice%202026-03.pdf">Invoice 2026-03.pdf</a>. Keep the link to the original PDF that the template already has.

SAVING
Save the finished report, as one complete HTML file, to exactly this path:
$_work/report.html
Write nothing anywhere else: Diptych puts the report beside the PDF, under the PDF's name with .html, once you are done. Do not change, move or delete any other file. When it is saved, reply with one line: what the document is.

THE FILES IN $_folder
PROMPT
    /bin/ls -1p "$_folder" | grep -v '^\.' | sed 's/^/- /'
}

# -- One PDF at a time -------------------------------------------------------
for pdf in "$@"; do
    case "$pdf" in /*) ;; *) pdf="$PWD/$pdf" ;; esac
    [ -f "$pdf" ] || { say "Not a file, left out: $pdf"; continue; }
    folder=$(dirname "$pdf")
    name=$(basename "$pdf")
    report="$folder/${name%.*}.html"
    work=$(mktemp -d "${TMPDIR:-/tmp}/diptych-report.XXXXXX")

    say ""
    say "== $name"
    pdf_text "$pdf" > "$work/text.txt"

    R_SOURCE_NAME=$name R_SOURCE_HREF=$(href "$name") R_PAGES=$(pdf_pages "$pdf") \
    R_GENERATED=$(date '+%Y-%m-%d %H:%M') R_AGENT=$agent \
        fill "$templates/template.html" > "$work/template.html"

    others=""
    if [ $# -gt 1 ]; then
        others="These were selected together with it, so are likely related: "
        for other in "$@"; do
            [ "$other" = "$pdf" ] || others="$others $(basename "$other");"
        done
    fi
    prompt=$(prompt_for "$pdf" "$folder" "$work" "$others")
    printf '%s\n' "$prompt" > "$work/prompt.txt"

    say "Reading and writing -- this takes a minute or more..."
    status=0
    # Nothing on standard input: headless, an agent would otherwise wait for
    # a prompt to be piped in.
    (
        cd "$agent_dir"
        case "$agent" in
            claude)
                claude -p "$prompt" \
                    --permission-mode acceptEdits \
                    --add-dir "$folder" --add-dir "$work" \
                    --allowedTools "Read,Glob,Grep,Write,Edit,Bash(ls:*),Bash(file:*),Bash(mdls:*),Bash(stat:*),Bash(head:*),Bash(cat:*),mcp__diptych"
                ;;
            codex)
                codex exec --skip-git-repo-check --sandbox workspace-write \
                    --add-dir "$work" "$prompt"
                ;;
            copilot)
                copilot -p "$prompt" --allow-all-tools --add-dir "$folder" --add-dir "$work"
                ;;
            gemini)
                gemini -p "$prompt" --yolo --include-directories "$folder,$work"
                ;;
            cursor-agent)
                cursor-agent -p --force "$prompt"
                ;;
            *)
                "$agent" -p "$prompt"
                ;;
        esac
    ) </dev/null || status=$?

    if [ ! -s "$work/report.html" ] || ! grep -qi '<html' "$work/report.html"; then
        say "No report was written for $name (the agent exited with $status)."
        say "What it was given is in $work"
        continue
    fi
    inline_css "$work/report.html" "$templates/report.css" > "$work/final.html"
    if [ -e "$report" ]; then
        /usr/bin/trash "$report" 2>/dev/null && say "The earlier $(basename "$report") is in the Trash."
    fi
    cp "$work/final.html" "$report"
    rm -rf "$work"
    say "Written: $report"
done
exit 0
