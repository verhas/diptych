# Diptych 1.8.1

Text Edit becomes an editor for JSON, XML, YAML and TOML: it colours them,
closes brackets, quotes and XML tags, formats JSON and XML, shows JSON, XML,
YAML and property lists as a tree that can be edited, and edits by lines as
IntelliJ does. And a folder's files can be put in an order of your own.

---

## Files in your own order

`⇧⌘↑` and `⇧⌘↓` move the selected file one place up or down in the pane. The
sort arrow goes, since the rows follow no column now. Clicking a header sorts
again, and leaving the folder forgets the order: it is kept in memory only. A
new file goes where the sort puts it among the files that were not moved.

---

## Typing

- **XML is helped along.** What the markup at the caret still needs is shown
  in grey after it -- `>` once a `<` is typed, `-->` in a comment -- and
  **Control-Space** takes it. After `</` the grey text names the innermost
  element still open, narrowed by what is typed, so Control-Space closes it.
  Closing a start tag, by typing `>` or taking it, puts in the end tag after
  the caret -- unless one further on already closes the element; Undo takes
  the end tag back first.
- **An attribute gets its quotes.** After an attribute's name the grey text
  is `=""`; Control-Space puts it in with the caret between the quotes.
- **Brackets and quotes close themselves**, and typing the closing one steps
  over it. Backspace between an empty pair takes both.
- **Return keeps the indentation** and adds a level after `{`, `[`, a start
  tag or a YAML `key:`; a closing bracket or end tag goes on its own line.
  Tab and Shift-Tab indent and outdent the selected lines, and Backspace in the
  indentation goes back a level.
- **Colours** for keys, strings, numbers, keywords, comments, tags and
  attributes, and the bracket or tag that matches the one at the caret is
  marked.

---

## Editing by lines, as IntelliJ does

- `⇧⌘↑` and `⇧⌘↓` move the line, or the selected lines.
- `⌘⌫` deletes them.
- `⌘C` and `⌘X` with nothing selected take the whole line -- and pasting it
  puts it above the caret's line.

---

## The tree

The button with the indented list, or `⌃⌘T`, shows a JSON, XML or YAML file
as a tree: Key, Type and Value, edited in place; nodes added by type,
duplicated, given another type, deleted, and dragged to move them. Every change
is a change in the text, touching only that node and its separators, so
comments and layout stay and Undo is the text's. A YAML file the tree cannot
read -- an explicit `? key`, a second document -- names the line where it
stopped.

- **Key and Value, with the Type column on request.** What a node is shows in
  its name -- an element blue, an attribute orange after an `@` badge,
  `#comment`, `<?…?>` -- and in its value's colour: numbers blue, booleans and
  null pink. Format ▸ Show Type Column, the tree's right-click menu, a
  right-click on its column headers or Settings bring the column back.
- **Add Child** (`⌃⌘N`) and **Add After** (`⌘↩`), in the Format menu, add a node
  like its neighbour without a menu; the right-click menu shows which kind
  each key adds.
- **An element becomes an attribute by its name.** An attribute is edited as
  `@name`: put `@` before an element's name and `<name>Diptych</name>` becomes
  `name="Diptych"` on its parent; take it away and the attribute is an element
  again. Make Attribute and Make Element in the right-click menu do the same.
- **Nodes move by the structure.** `⇧⌘↑` and `⇧⌘↓`, or `⌘↑` and `⌘↓`, move
  the selected node and all it holds past its neighbour, into an open
  container next to it, or out of its own at the end -- as Move Lines does in
  the text.
- A value over several lines shows on one row, its breaks as `↩`, and is edited
  in a **text area**, line breaks and all -- comments, CDATA, text, and the
  DOCTYPE and processing instructions, which could not be edited before. Its
  corner drags it larger; Done shows its key, `⌘↩`.
- **Line numbers** beside the rows, when the text has them: the line each node
  starts on.
- **Copy XPath**, **Copy JSON Path**, **Copy YAML Path** and **Copy Key Path**
  on the right-click menu.
- **Find** (`⌘F`) in the tree: names and values, folded away or not; Return
  for the next, `⇧↩` for the one before.

---

## The Format menu

Format Document (`⌥⌘L`) for JSON and XML -- an invalid file is not touched, and
the alert shows where it breaks; text, CDATA, mixed content and
`xml:space="preserve"` keep every space -- Compact JSON, Comment Lines (`⌘/`), Move
Lines, Delete Lines, Go to Line (`⌘G`) and Show as Tree.

---

## Property lists

A `.plist` opens as its tree of keys and values -- String, Integer, Real,
Boolean, Date, Data, Dictionary, Array -- and its text is the XML. A binary
plist is shown as XML and saved as binary; **Save XML** or **Save Binary**
beside Save converts it.

---

## Go to Line

`⌘G` in Text Edit asks for a line and goes there: the caret to its start in
the text, the node on it selected and scrolled to in the tree.

---

## Structure emphasis

The lines of the structure around the caret, shaded: the smallest one at 1,
the one around it at 2, up to 5. `⌥⌘↑` and `⌥⌘↓`, in the Format menu, change
the level for the window; Settings sets the highest and where a window starts.

---

## Text size

View ▸ Bigger Text, Smaller Text and Actual Size (`⌘+`, `⌘−`, `⌘0`) size Text
Edit's text and tree while it is in front, and the panes otherwise.

---

## Settings

**Settings ▸ Behaviour ▸ Text Edit** sets the indentation per format -- spaces
or tabs, and how many; YAML is always spaces -- whether pairs and end tags are
put in, and how Format Document lays the text out.

---

## The right-click menu

A file's **Text Edit** is named for its format -- **JSON Edit**, **XML Edit**,
**YAML Edit**, **TOML Edit** -- by the extensions in Settings.

The text's right-click menu is Cut, Copy and Paste and the Format menu's items
for the file -- no fonts, spelling or services. The tree's has them too.

---

## Fixes

- **Clicking a value over several lines in the tree gave a one-line field**
  that could not show it. Such a value is edited in the text area only.
- **Opening the text area could write `↩` into the file, Cancel or not.** The
  row's one line, with `↩` for each line break, was kept as the area opened.
  It is dropped now, and the row's one line is never written.
- **Structure emphasis started an XML element at the end of its start tag.**
  A start tag over several lines -- a root element with its namespaces --
  shaded only its last line; the element is now shaded from its `<`.
- **⌘F did nothing in the tree.** It looked in the hidden text.
- **Wrap lines** is greyed out in the tree, which has no lines to wrap.
- **Text typed in a tree row was lost when you clicked elsewhere.** It stayed
  in the row, unsaved, in the colours of a row being edited -- white on a light
  background. Clicking away now keeps it, as Return does.
- **The menus acted on the panes while Text Edit was in front.** Go ▸
  Enclosing Folder stood ready and `⌘↑` seemed to run it, Bigger Text grew the
  panes behind the editor, and File's commands on files did nothing. They are
  greyed out now, and Format is greyed out outside Text Edit.
- **Dragging a tree column rearranged the panes' columns.** The panes took the
  tree for one of theirs; resizing its columns changed the panes' widths too.
  The tree's columns no longer move, and the panes leave them alone.
- **YAML with anchors and tags is no longer called wrong.** A key whose value
  is only an anchor or a tag -- `defaults: &defaults`, `point: !vector` -- with
  its mapping indented below, as in Docker Compose and CI files, was reported
  as "A key cannot be indented under a line that already has its value".

---

## Upgrading

Nothing to do.

---

*1133 tests.*
