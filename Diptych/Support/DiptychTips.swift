import Foundation

/// The pool the "Did You Know?" startup dialog draws from -- plain trivia
/// about using Diptych, one sentence each, mined from what the app actually does.
enum DiptychTips {
    static let all: [String] = [
        "Diptych shows two folders side by side, Norton Commander style, and every command works from"
            + " whichever pane is active.",
        "the active pane always carries a thin accent-coloured line along its top edge, so you can"
            + " tell at a glance which side a command like Copy to Other Pane will act from.",
        "plain Tab switches which of the two panes has keyboard focus.",
        "Option-Tab cycles through every window Diptych has open -- Get Info, Compare, Text Edit, Bin"
            + " Edit, Rename Many, all of them -- not only the two-pane browser windows.",
        "with only one Diptych window open, Option-Tab instead swaps that window's own left and right"
            + " panes, so the key still does something.",
        "the pane filter box takes either a shell pattern like *.txt or, with the RegEx checkbox"
            + " ticked, a real regular expression.",
        "the Hide checkbox next to a filter removes non-matching rows entirely, instead of just"
            + " dimming them the way the filter does by default.",
        "a half-typed regular expression that will not compile turns the filter text red, in the pane"
            + " filter, the Compare Folders filter, and the Rename Many search field alike.",
        "clicking the path text at the top of a pane turns it into an editable field, the same as"
            + " Finder's Go to Folder, and Command-Shift-G opens it directly.",
        "the path field completes like a shell: press Tab and it extends as far as every matching"
            + " folder name agrees, then stops.",
        "typing ../ in the path field is resolved relative to the folder that pane is showing, not to"
            + " wherever the Diptych process itself happens to consider its working directory.",
        "typing a path that does not exist leaves you in the path editor to fix the typo, rather than"
            + " navigating to what looks like an empty folder.",
        "Command-[ and Command-] step back and forward through a pane's own navigation history.",
        "Command-Up Arrow, or the up-arrow button in the path bar, goes to the enclosing folder.",
        "Command-U swaps the left and right panes.",
        "Command-2 toggles between showing one pane and showing both.",
        "Control-Command-S shows or hides the sidebar.",
        "Command-Shift-period shows or hides files whose names begin with a dot.",
        "typing while a pane has focus jumps straight to the first file whose name starts with what"
            + " you typed, with no need to press any special key first.",
        "Command-Plus, Command-Minus and Command-0 change the size of the text in both panes;"
            + " Command-Plus is silently mirrored by Command-Equals, because the menu's own Command-Plus"
            + " only matches when Shift is actually held.",
        "a locked-out folder -- a Time Machine volume, a protected system folder -- looks exactly"
            + " like an empty one until Diptych tells you it could not be read, with a button straight to"
            + " Full Disk Access in System Settings when that is the reason.",
        "opening a folder on a disk that is still spinning up shows a spinner and a Cancel button"
            + " instead of freezing the pane.",
        "dragging a file out of Diptych hands Finder a real file reference with the correct"
            + " extension, not a generic name like item-003.log.log.",
        "dragging a file over a folder row and pausing makes it flash, and after a short wait the"
            + " pane navigates into that folder on its own, the same spring-loading Finder does.",
        "if you drop before the spring-loading delay finishes, the file lands in the pane's current"
            + " folder instead of the one you were hovering over.",
        "Command-D compares the two selected items -- two files open a text or byte comparison, two"
            + " folders open a Compare Folders window.",
        "comparing a file with a folder is refused outright, rather than guessing which one you"
            + " meant.",
        "comparing an item with itself -- even by two different paths that point at the same file --"
            + " is refused too, with a message saying so.",
        "Compare Folders colours each pair with a small lettered badge: N for name, S for size, C for"
            + " content, P for permissions, X for extended attributes, A for access control list, M for"
            + " modified date, B for creation date, O for owner or group, and F when one side is a file and"
            + " the other a folder.",
        "a legend at the bottom of every Compare Folders window spells out what each lettered badge"
            + " means, since the letters alone stop being obvious the moment you have not opened the window"
            + " in a month.",
        "Compare Folders recognises a renamed file: two files with different names and locations but"
            + " identical bytes are shown as one pair, not as two separate \"missing\" entries.",
        "the Ignore Missing checkbox in Compare Folders hides anything that exists on only one side,"
            + " leaving only the pairs that exist on both.",
        "the Refresh button in Compare Folders is always available, even when nothing about the"
            + " checkboxes has changed, in case the folders themselves have changed since the last"
            + " comparison.",
        "Compare Folders automatically switches on Recurse into Hidden Folders when either folder you"
            + " started comparing itself begins with a dot, so comparing two .git folders looks inside their"
            + " own hidden subfolders by default.",
        "double-clicking a folder pair inside Compare Folders opens a second, narrower Compare"
            + " Folders window for just that subfolder.",
        "Command-G inside Compare Folders sends the selected pair back to whichever Diptych tab the"
            + " comparison was opened from, selecting it in both panes.",
        "Command-I inside Compare Folders opens Get Info on both sides of the selected pair, so you"
            + " can put the two windows side by side and compare tags, extended attributes and ACLs by eye.",
        "\"Same content as:\" under a file in Compare Folders means it shares its bytes with some other"
            + " file elsewhere in the comparison too, beyond the one pair it is already matched to.",
        "the two-file comparison window shows a small padlock beside each file; clicking it is how"
            + " you unlock that one side for editing.",
        "in the two-file comparison window, Command-Z and Command-Shift-Z undo and redo only the side"
            + " you have unlocked.",
        "the Ignore Spacing checkbox in a text comparison treats runs of whitespace as equal, without"
            + " changing what is actually on disk.",
        "comparing two files that turn out not to be text falls back to a byte-by-byte comparison,"
            + " with Bin Edit offered as the way to actually look inside either one.",
        "when a file was set aside as a clash -- a copy kept next to the original -- the comparison"
            + " window offers a single Replace button that saves your edits and puts your version back in"
            + " the original's place.",
        "Text Edit preserves whatever line endings a file already had -- Windows CRLF stays CRLF --"
            + " even after you have edited and saved it.",
        "Text Edit preserves a file's original text encoding on save, including encodings that are"
            + " not UTF-8.",
        "Text Edit refuses to open a file that looks binary, and says so rather than pretending it"
            + " can edit it.",
        "Text Edit tells the difference between a file that looks binary and a file it simply is not"
            + " allowed to read, and does not send you to Bin Edit for a permission problem Bin Edit cannot"
            + " solve either.",
        "a file you cannot write to opens read-only in Text Edit, with an orange \"Read only\" label"
            + " explaining why, rather than letting you type into something that cannot be saved.",
        "Command-F opens Text Edit's own find interface.",
        "Text Edit and the two-file comparison window refuse to both have the same file open at once,"
            + " so neither one can silently save over what the other is holding.",
        "Bin Edit memory-maps the file it opens, which is what lets it open a 60 MB file instantly"
            + " instead of reading the whole thing first.",
        "Bin Edit can show 8, 16, 32, 48 or 64 bytes per line, and a Decimal checkbox switches every"
            + " byte between two hex digits and three decimal digits.",
        "Bin Edit's Find box reads its query as text by default, or as hex byte pairs like 48 65 6c"
            + " when the Hex checkbox is ticked.",
        "Command-G and Command-Shift-G find the next and previous match in Bin Edit, the same as"
            + " everywhere else in Diptych that has a find field.",
        "Command-Slash in Bin Edit inserts that many zero bytes right before the cursor, pushing"
            + " everything after it forward.",
        "Command-Delete in Bin Edit removes the selected bytes and pulls everything after them back"
            + " to fill the gap.",
        "pressing Delete in Bin Edit puts the selected bytes back to whatever the file on disk"
            + " actually holds, rather than zeroing them.",
        "a byte you have changed in Bin Edit is shown in red until you either revert it or save, so"
            + " you can see exactly what would be written.",
        "saving in Bin Edit tells you plainly whether the changed bytes will be written in place or"
            + " the whole file rewritten because its length changed -- and warns that there is no undo and"
            + " no backup.",
        "Shift-clicking in Bin Edit's grid extends the selection from wherever the cursor already"
            + " was, so you can click the start, scroll, and Shift-click the end of a selection longer than"
            + " the window.",
        "the Get Info window has seven tabs: General, Ownership, Tags, Attributes, Access, Details"
            + " and Open By.",
        "Get Info's status line at the bottom always shows the file's full path, not just its"
            + " enclosing folder -- useful the moment you have more than one Info window open at once.",
        "you can rename a file directly from the General tab of Get Info, with a Rename button right"
            + " next to the name field.",
        "the Dates panel in Get Info lets you set the Created and Modified dates directly; Added and"
            + " Accessed are shown but cannot be changed, since one belongs to the folder's own index and"
            + " the other to the kernel.",
        "changing a file's owner in Get Info needs an administrator password, because only root is"
            + " allowed to give a file to somebody else on macOS.",
        "changing a file's group in Get Info needs no special permission at all, as long as you"
            + " already belong to that group.",
        "Get Info's Permissions panel gives Read, Write and Execute checkboxes for User, Group and"
            + " Others separately, and for a folder the execute checkbox is labelled Search instead.",
        "for a folder, Read alone lists the names inside it; Search allows walking into what is"
            + " listed. Read without Search shows names you cannot then open.",
        "Get Info's Permissions panel also exposes setuid, setgid and sticky as their own toggles,"
            + " each with a one-line explanation of what it actually does -- setuid is how /usr/sbin/sudo"
            + " becomes root, and sticky is what makes /tmp safe to share.",
        "setuid, setgid and sticky each share their execute column's letter, showing as s, s or t in"
            + " place of x once switched on.",
        "the Tags tab lets you click any of the seven Finder colours to add or remove that tag, and"
            + " type a name of your own for an uncoloured tag.",
        "typing a tag name that matches one of the seven Finder colours automatically gives it that"
            + " colour.",
        "for a folder, the Tags tab also offers tinting the folder icon itself with its tag colour"
            + " and picking an SF Symbol to draw on top of it.",
        "Get Info's Attributes tab lets you view and edit any text-valued extended attribute in"
            + " place, and add a brand new one by name and value.",
        "an extended attribute macOS marks as protected is still listed in Get Info, even though"
            + " nobody -- not even an administrator -- is allowed to read what is actually in it.",
        "a binary extended attribute, like a saved bookmark or a property list, is shown as a hex"
            + " preview in Get Info rather than as editable text, since editing it as text would corrupt it.",
        "Get Info's Access tab edits a file's access control list as the same plain text the ls -le"
            + " command shows; leaving it empty removes the list entirely.",
        "the Details tab in Get Info shows whatever a file says about itself internally -- EXIF data"
            + " in a photo, ID3 tags in an audio file -- and it is read-only, because changing one of those"
            + " fields means rewriting the whole file.",
        "the Open By tab in Get Info lists which of your own running programs currently have this"
            + " file, or this folder, open, and tells reading apart from writing with a different icon for"
            + " each.",
        "Open By's list is a one-moment snapshot with a timestamp, not a live view, since a program"
            + " can open or close a file between one glance and the next.",
        "Open By can only see programs that belong to you; anything belonging to another user on the"
            + " same Mac is counted but cannot be looked inside.",
        "a symbolic link's target is directly editable in Get Info, and a relative target is kept"
            + " relative rather than being rewritten as an absolute path.",
        "Rename Many renames a whole folder's worth of files at once using one regular expression and"
            + " one replacement pattern, with $1 for the first captured group.",
        "Rename Many's search pattern has to match a file's whole name, not just part of it.",
        "Rename Many shows every file's proposed new name before anything actually happens, and dims"
            + " -- or with a checkbox, hides -- the files that do not match.",
        "Rename Many works out the entire plan before touching a single file, and refuses the whole"
            + " batch if any two files would end up with the same name.",
        "when renaming file A to B would collide with file B also being renamed to C, Rename Many"
            + " figures out the order on its own: B moves out of the way first.",
        "when two files would swap names entirely, Rename Many steps one of them aside under a"
            + " temporary name that starts with a dot before bringing it back under its real new name, so"
            + " the plan never gets stuck.",
        "double-clicking a folder inside the Rename Many list navigates into it, without leaving the"
            + " window.",
        "the sidebar lists every mounted volume automatically, and any folder you drag there as a"
            + " favourite, in its own section below.",
        "favourites in the sidebar can be dragged up and down to reorder them; volumes cannot, since"
            + " their order belongs to the system rather than to you.",
        "an ejectable volume in the sidebar gets its own eject button right in the row, and in its"
            + " right-click menu.",
        "the scripts feature lets you run your own programs from Diptych's own menu and right-click"
            + " menu, but it is switched off by default in Settings.",
        "scripts live in ~/.diptych/scripts and are read once when Diptych starts, deliberately not"
            + " while it is running, so a script cannot be swapped out between being approved and being run.",
        "Developer Mode adds the menu item \"File > Read the Scripts Folder Again\" for anyone actively editing"
            + " scripts, without relaxing any of the safety rules around running them.",
        "Diptych refuses to run any script in its scripts folder that still carries the quarantine"
            + " flag macOS attaches to anything downloaded from outside the Mac.",
        "Diptych refuses to run a script owned by anyone other than you, even if it otherwise lives"
            + " in your own scripts folder.",
        "a script has to be completely unwritable -- not merely \"not writable by others\", but not"
            + " writable by anyone at all, owner included -- or Diptych will not run it, and nothing in"
            + " Developer Mode lifts that rule.",
        "a script also has to be unreadable by every account but your own, since a script is a"
            + " reasonable place to keep something private.",
        "Diptych's own permission editor -- select the file, press Command-Option-P -- is the"
            + " quickest way to lock a script down to owner-read-only.",
        "even a script you have already approved and run before is checked again, against the file on"
            + " disk, at the exact moment you try to run it again -- so a change since it was approved is"
            + " always caught.",
        "a script's approval is remembered by the exact content you agreed to, so editing the script"
            + " even slightly makes Diptych ask again.",
        "a script file's own header comments -- everything from the line after the shebang up to the"
            + " first non-comment line -- declare its name, description, which extensions it applies to, how"
            + " many items it needs, and the command it runs.",
        "a script's call line is split into separate arguments before anything is substituted into"
            + " it, which is what lets it run correctly on a file called \"my notes (draft).txt\" with no"
            + " quoting rules for anybody to remember.",
        "the $@ placeholder in a script's call line passes every selected item as its own separate"
            + " argument; the shell-style $* is refused outright, since it is exactly the shorthand that"
            + " breaks on a space in a name.",
        "a script can be restricted to only being offered inside specific folders, or inside a folder"
            + " and everything beneath it, using its own header settings.",
        "Command-Option-P opens the permission editor for the current selection.",
        "the Files menu shows Track This File and Never Track This File only for files Git does not"
            + " already know about, and Stop Tracking only for files it does.",
        "Stop Tracking removes a file from version tracking on your next send, but leaves the file"
            + " itself sitting right there on disk.",
        "Apple Intelligence is switched off by default for everything Diptych can use it for, and the"
            + " toggle to turn it on is disabled outright on a Mac where Apple Intelligence is not actually"
            + " available.",
        "Apple Intelligence-suggested names always land in an ordinary, editable rename field --"
            + " Diptych never renames a file to a suggestion without you seeing and accepting it first.",
        "Rename with Suggested Name is Command-F2, distinct from the plain F2 that starts an ordinary"
            + " rename.",
        "New from Clipboard can also ask Apple Intelligence to suggest a name for the file it is"
            + " about to create, from whatever text or image is actually on the clipboard.",
        "Apple Intelligence naming runs entirely on this Mac; nothing about a file's contents is sent"
            + " anywhere, and the settings pane says exactly that.",
        "with UTF-8 switched off for suggested names, accented letters are transliterated to plain"
            + " ASCII -- ö becomes o, and letters from other alphabets are respelled in Latin ones.",
        "a separate setting lets ä, ö and ü become ae, oe and ue instead of plain o, u and a -- the"
            + " German convention -- but only when UTF-8 for names is switched off.",
        "you can choose a character, like an underscore, to stand in for spaces in every suggested"
            + " file name.",
        "the number of characters read from the start of a file before asking for a suggested name is"
            + " configurable, with four presets or a number of your own.",
        "Apple Intelligence's naming prompt is an editable template file on disk, not something baked"
            + " into the app -- its location is shown right in Settings.",
        "a naming template placed in a folder, starting with a line like \"# under:"
            + " ~/Documents/Scans\", is used only in that folder and everything beneath it instead of the"
            + " general template, and when several such templates could apply, the nearest one wins.",
        "an edit to a naming template takes effect on the very next suggestion Diptych makes, with no"
            + " need to restart the app.",
        "Diptych does not bundle its own copy of Git -- it finds and runs whatever git program is"
            + " already installed on your Mac, inheriting your own SSH keys, credential helper and hooks in"
            + " the process.",
        "version tracking is switched off by default, since it runs a program Diptych itself did not"
            + " write and cannot vouch for.",
        "the Git settings pane shows the exact program found, what it reports as its own version, and"
            + " who signed it -- while being upfront that none of that is proof it is really Git rather than"
            + " something pretending to be.",
        "you can point Diptych at a different git program by hand, but whatever file you choose has"
            + " to be literally named \"git\", which stops picking the wrong file by accident without"
            + " pretending to be a security check.",
        "Diptych asks the shared repository for status with one call per repository, not one call per"
            + " folder or per file, because a single status call was measured at 46 to 67 milliseconds, most"
            + " of it just spawning the process.",
        "\"Check for changes automatically when a folder is first opened\" runs at most once per"
            + " tracked folder per launch, and only when that folder actually has local changes.",
        "in a tracked folder's pane, brown means a new, untracked file; green means new and already"
            + " tracked; blue means changed, renamed, deleted, or a removal waiting to be sent; red means"
            + " the file clashes with the shared copy or has an unfinished merge; purple means somebody else"
            + " has sent a newer version you do not have yet.",
        "the status line under a tracked pane shows the branch name plus how many changes you have"
            + " that the shared copy does not, and how many of yours have not been sent yet, each ageing"
            + " visibly the longer it has been since Diptych last checked.",
        "the Send My Work dialog lets you deselect individual files before sending, and separately"
            + " warns about new files that are not yet tracked at all so they are never silently left"
            + " behind.",
        "Send My Work refuses to send anything while a merge is left half-finished in the folder,"
            + " since Diptych never creates that state itself and treats it as something only another Git"
            + " tool could have caused.",
        "\"When sending, also bring in what other people have sent\" catches you up automatically if a"
            + " push is refused because the shared copy has moved on, instead of stopping and making you ask"
            + " for an update yourself.",
        "the Copy Details button in Git settings assembles a full diagnostic report about your Git"
            + " setup in one paste, meant for whoever configured the repository in the first place.",
        "renaming a file on a case-sensitive-looking change that a Mac's own disk treats as no change"
            + " at all -- Untitled.png to untitled.png -- is still recognised and followed as a real rename"
            + " by Diptych's version tracking.",
        "Diptych plays a short sound after a copy, a move, and a move to Trash, each chosen"
            + " independently from every sound installed on the Mac, with \"None\" for silence.",
        "the master \"Play sounds\" switch turns all three off at once; the individual pickers in"
            + " Settings still preview a sound when you choose it, even with sounds switched off.",
        "New from Clipboard makes a file out of whatever is on the pasteboard: text becomes a plain"
            + " text file, a picture becomes an image in the format you choose.",
        "New from Clipboard's image format can be PNG, JPEG, PDF, asked each time, or switched off"
            + " entirely so the command disappears from every menu.",
        "if the clipboard already holds vector PDF data -- copied straight out of a drawing program"
            + " -- New from Clipboard keeps it as a PDF untouched, rather than flattening it into a bitmap"
            + " first.",
        "JPEGs made by New from Clipboard are saved at roughly 90 percent quality.",
        "Cut puts files on the clipboard exactly the way Copy does; only Diptych's own memory that"
            + " this particular clipboard state was a cut tells the two apart, so anything else that touches"
            + " the clipboard quietly cancels the cut.",
        "Control-Command-V pastes as a symbolic link instead of copying the actual file.",
        "the spacebar toggles a Quick Look preview of the selected file, and pressing it again closes"
            + " the preview, exactly the way Finder's own spacebar preview works.",
        "arrow keys still move the pane's own selection while a Quick Look preview window has"
            + " keyboard focus.",
        "Quick Look shows a real generated listing for a folder or a recognised archive, instead of"
            + " the plain folder icon and size it shows by default.",
        "a file with no extension the system recognises -- a .env file, a Dockerfile, an oddly named"
            + " config -- still gets previewed as text by Quick Look if its bytes actually look like text.",
        "Markdown files are rendered to formatted HTML for Quick Look preview, rather than shown as"
            + " their raw source text.",
        "a .DS_Store file previews as a readable page describing the Finder window state it actually"
            + " stores -- icon positions, window arrangement, visible columns -- instead of showing nothing"
            + " useful at all.",
        "Quick Look's preview updates live as the selected row changes, and closes itself outright if"
            + " the file it was showing gets deleted out from under it.",
        "the toolbar's buttons, their order, and which of the toolbar's three sections they sit in"
            + " are all configurable in Settings.",
        "Send My Work, Get the Latest and Check for Changes only ever appear in the toolbar inside a"
            + " folder that is actually tracked, and only while version tracking itself is switched on.",
        "when a later version of Diptych adds a new toolbar button that belongs beside an existing"
            + " one -- Check for Changes beside Get the Latest, for instance -- it is inserted next to that"
            + " button if you have already moved it, rather than landing wherever the plain defaults would"
            + " put it.",
        "the Name column can never be turned off and is always shown first; every other column can be"
            + " switched on or off and dragged into whatever order you like in Settings.",
        "Diptych's available columns are Name, Size, Kind, Date Modified, Date Created, Date Added,"
            + " Extension, Permissions, Owner, Group, Tags and Git.",
        "turning a column off and back on again returns it to the same position it held before,"
            + " instead of moving it to the end of the list.",
        "Diptych keeps one shared undo history for the whole application, the way Finder does, rather"
            + " than a separate one per window.",
        "every undo step is checked against what is actually on disk before it is offered, so a file"
            + " that has since been replaced by another of the same name is simply left alone rather than"
            + " undone by mistake.",
        "undoing a copy, or undoing the creation of a new file, sends what it removes to the Trash"
            + " rather than deleting it outright -- and redoing takes it straight back out of the Trash.",
        "Control-Command-Z opens Undo or Redo Many, which lets you pick several past steps to undo or"
            + " redo at once instead of pressing Command-Z over and over.",
        "Control-Command-Z and Control-Command-R are caught directly at the keyboard rather than"
            + " through the ordinary menu bar, because Control-Command key combinations do not reliably"
            + " reach macOS's own menu shortcut matching.",
        "the undo history only holds the last 50 steps, and lives in memory only -- it does not"
            + " survive quitting and restarting Diptych.",
        "Move to Trash checks, after the fact, that a file it just asked macOS to trash has actually"
            + " gone -- catching the case where a system-protected file reports success but was never"
            + " actually removed.",
        "when a write genuinely fails, Diptych works out the real reason rather than repeating"
            + " macOS's own generic \"you don't have permission\" message, which is wrong at least as often as"
            + " it is right.",
        "a locked file, in the Finder sense, is called exactly that -- \"locked\" -- with a pointer"
            + " straight to unlocking it in Get Info, rather than a vague permissions message.",
        "if a write fails for a reason that genuinely is not about permissions at all -- disk full, a"
            + " read-only volume, something else macOS itself is refusing -- Diptych says so plainly instead"
            + " of sending you off to check permissions that were never the problem.",
        "double-clicking, or pressing Return on, an application bundle walks into it as an ordinary"
            + " folder, instead of launching the application the way Finder's double-click does.",
        "\"Run App\" is its own dedicated right-click command, offered only on application bundles, and"
            + " it is the one deliberate way to actually launch one from inside Diptych.",
        "right-clicking the empty space below the last row in a pane still gives you a menu: New"
            + " Folder, New File, New from Clipboard, Paste, Paste as Link, Rename Many, Select All and"
            + " Refresh.",
        "Command-Shift-N makes a new folder in the active pane; Command-Option-N makes a new empty"
            + " file.",
        "Command-Shift-C copies the current selection to the other pane; Command-Shift-M moves it"
            + " there instead.",
        "Command-Option-R reveals the current selection in Finder; Command-Option-T opens a Terminal"
            + " window in the active pane's folder.",
        "Command-Option-C copies the selected items' plain file names to the clipboard;"
            + " Command-Option-Shift-C copies their full paths instead.",
        "F1 in the function-key bar copies a description of the current selection meant to be pasted"
            + " straight into a chat with an LLM.",
        "F2 renames the selected file in place; F3 opens Quick Look on it; F4 opens the permission"
            + " editor.",
        "F5 copies the current selection to the other pane and F6 moves it there, mirroring the"
            + " classic Norton Commander layout.",
        "F7 creates a new folder and F8 moves the current selection to the Trash, both right there on"
            + " the function-key bar along the bottom of the window.",
        "\"Ask before quitting\" is switched on by default, since Command-Q sits one key away from"
            + " Command-W and Command-A on a standard keyboard.",
        "Command-T opens a new tab, a fresh two-pane view, without opening a whole second window.",
        "Copy, Cut, Paste and Select All act on whichever pane has focus, and fall back to ordinary"
            + " text editing the moment a text field is actually focused instead.",
        "an executable file's row carries a small orange terminal icon right next to its name.",
        "a symbolic link's row carries an arrow icon, and hovering over it names exactly where the"
            + " link points.",
        "a Finder tag with a colour tints the whole row it is on in the pane listing, not just a"
            + " small dot beside the file's name.",
        "a folder containing several different kinds of Git changes lists every one of them,"
            + " comma-separated and each in its own colour, rather than collapsing them into a single"
            + " worst-case word.",
        "the status line at the bottom of a pane totals the size of only the selected files, leaving"
            + " folders out of that number since their own size on disk is not what \"selected\" is really"
            + " asking about.",
        "Settings has seven tabs of its own: Columns, Toolbar, Appearance, Behaviour, Apple"
            + " Intelligence, Version Tracking and Sounds.",
        "the pane font, and its size, can be changed independently of the system font from the"
            + " Appearance tab, with a live preview row showing exactly what it will look like.",
        "Settings, the sidebar and every dialog box keep their own fixed size regardless of what font"
            + " size you pick for the panes -- only the file listings themselves follow it.",
        "\"List folders before files\" is on by default, but switching it off is worth doing the moment"
            + " you are sorting by size or by date rather than by name.",
        "Compare Folders only ever checks content -- and, by way of matching renamed files, the name"
            + " along with it -- by default; permissions, extended attributes, ACL, and every date and"
            + " ownership check start switched off.",
        "the Behaviour tab in Settings lets you change which checkboxes a brand new Compare Folders"
            + " window starts with; each open window still keeps its own copy you can change independently"
            + " afterward.",
        "a script is only offered in the menu when every single item you have selected qualifies for"
            + " it -- kind, extension and folder scope all have to match every item, not just most of them.",
        "a script declared with no item requirement at all is offered based on the folder currently"
            + " showing in the pane, rather than on whatever happens to be selected.",
        "in a script's call line, $0 stands for the script's own path, and $1, $2 and so on stand for"
            + " one selected item each, counting from one.",
        "which scripts you have already agreed to run is recorded in a small file written with"
            + " permissions that only you can read.",
        "losing the file that remembers approved scripts is not a security problem -- Diptych simply"
            + " asks you to approve each script again, the same as the first time.",
        "Diptych quietly asks macOS not to add \"Start Dictation\" or \"Emoji & Symbols\" to its"
            + " Edit-style menu, since neither does anything useful in a file manager.",
        "tooltips throughout Diptych, including the little difference badges in Compare Folders,"
            + " appear almost immediately rather than after the roughly 1.5-second delay macOS normally"
            + " uses.",
        "quitting Diptych with unsaved changes open somewhere does not lose them silently -- every"
            + " open editor or comparison window is asked about its own unsaved changes separately, only"
            + " once it is actually being closed.",
        "the sidebar draws a plain placeholder icon for a volume until its real icon has been fetched"
            + " in the background, so a sleeping external disk spinning back up never freezes the rest of"
            + " the window.",
        "the New Folder and New File dialogs name the exact folder the new item will be created in"
            + " before you confirm, so there is no surprise about where it lands.",
        "the permission editor lets you type octal digits straight into the Permissions column, and"
            + " the column heading itself relabels to User, Group or Other while your caret sits in that"
            + " field.",
        "undo tracks a file by its device and inode number, not by its name, so renaming or moving a"
            + " file before you undo an earlier step does not confuse which file the undo actually applies"
            + " to.",
        "undo and redo menu items are named after the actual operation they would reverse -- \"Undo"
            + " Move\" or \"Redo Rename\" -- rather than a single generic \"Undo\" that never says what it is"
            + " about to do.",
        "changing permissions or ownership is itself a step in Diptych's undo history, right"
            + " alongside copies, moves and renames.",
        "a comparison window's Wrap checkbox wraps long lines on both columns at once, kept perfectly"
            + " in step so the two sides never drift out of alignment with each other.",
        "the little arrow button between the two columns in a text comparison copies just that one"
            + " difference across to the other side, without touching anything else in the file.",
        "a horizontal scrollbar only appears under a text comparison when some line is actually too"
            + " long to fit -- it is not sitting there permanently taking up space.",
        "the symbol picker in Get Info's folder-tint panel searches by typing part of a name, live,"
            + " against every SF Symbol macOS ships.",
        "Diptych keeps exactly one keyboard event monitor for the whole application, which is what"
            + " lets the function-key bar, F1 through F8, work the same in every window without each one"
            + " fighting over the keys.",
        "a sheet, like New Folder's naming prompt, takes over the keyboard entirely while it is open,"
            + " so none of Diptych's other shortcuts can fire underneath it by accident.",
        "Copy Prompt's wording lives in an editable template file at ~/.diptych/prompts/prompt1.tmpl,"
            + " written out the first time it is needed, so you can change exactly what F1 puts on the"
            + " clipboard.",
        "Copy Prompt never includes the contents of any file, only the same metadata already sitting"
            + " in the pane -- it is a formatter, not something that reads your files for you.",
        "Copy Prompt wraps every file name in its own fenced block and says outright that what is"
            + " inside it is data, not instructions, since a downloaded file's name is exactly the kind of"
            + " thing a prompt injection could hide in.",
        "plain text typed into a pane's filter box matches as a fragment anywhere in the name --"
            + " typing inv lists every file with \"inv\" in it, wherever it falls.",
        "typing a pattern with a star, question mark or square bracket into the filter box switches"
            + " it to a shell glob automatically, the same rules a shell itself uses.",
        "Diptych remembers each window's position and size, and each pane's folder and selection,"
            + " across a full quit and relaunch, in a small hand-editable JSON file at"
            + " ~/.diptych/state.json.",
        "pressing Back or Forward skips silently over any folder that no longer exists on disk,"
            + " rather than getting stuck retracing the same dead end over and over.",
    ]
}
