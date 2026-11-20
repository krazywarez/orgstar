# App Store metadata

## Subtitle

Org mode editor and agenda

## Description

orgstar is an editor for Org mode files on iPhone and iPad. It reads and writes the same plain-text .org files Emacs does and leaves every byte you didn't change as it was, so your folder stays in step with Emacs, the Mac app and whatever sync tool you use.

Work on folders you choose in iCloud Drive or in another app's storage, such as a Syncthing folder. There is no database of your notes: orgstar keeps an index for search and the agenda, rebuilt from the files whenever they change.

EDITOR
- Headings, TODO keywords, priorities, tags, timestamps, links, lists, tables and source blocks, styled as you type
- A key bar for promoting, demoting and moving headings, TODO state, checkboxes, dates, tags and links
- Hardware keyboard support with Org's key bindings
- Sync conflicts merged into your edits, with a sheet to resolve overlapping changes

AGENDA
- Scheduled items, deadlines and timestamps from all your files, by day
- Habits with their consistency graph
- Events from the Calendar app alongside your entries
- Reminders before timed entries, and an app badge counting overdue items

CAPTURE
- Capture templates with questions, as in Org
- Capture from the share sheet, from Shortcuts, from org-protocol links, or from a Lock Screen widget or Control Center control

CLOCKING
- Clock in and out of entries, with a Live Activity showing the running clock
- Clock reports

AND MORE
- Search across file names, headings and text
- Table formulas
- Tangling source blocks into files
- Export to HTML and Markdown
- Home Screen and Lock Screen widgets: Today, Up Next, Habits and Capture
- Spotlight search and Quick Look previews of .org files
- Themes and settings read from the same configuration folder as the Mac app

ORGSTAR+
Editing, the agenda, capture, clocking, tables and search are free. orgstar+, monthly, yearly or as a one-time lifetime purchase, adds:
- Running and tangling source blocks
- PDF, Word and rich text export
- Encrypted entries
- Org-roam nodes, daily notes and backlinks
- Widgets, the Apple Watch app and the clock Live Activity
- Calendar events and reminders in the agenda
- Shortcuts actions
Everyone who downloaded orgstar before orgstar+ keeps all of it.

## Keywords

org-mode,emacs,outline,todo,agenda,plain text,notes,tasks,gtd,planner,journal,org file,clock

## Copyright

2026 Christian Cleberg

## Privacy policy URL

https://krz.sh/privacy/orgstar/

## macOS

The Mac App Store app shares the iOS app's record and bundle ID (Universal Purchase). Subtitle, copyright and privacy policy URL above apply to both; the sections below are the macOS version's own.

### Description

orgstar is an editor for Org mode files on the Mac. It reads and writes the same plain-text .org files Emacs does and leaves every byte you didn't change as it was, so your folder stays in step with Emacs, the iPhone and iPad app and whatever sync tool you use.

Work on folders you choose, in iCloud Drive, a Syncthing folder or anywhere else. There is no database of your notes: orgstar keeps an index for search and the agenda, rebuilt from the files whenever they change.

EDITOR
- Headings, TODO keywords, priorities, tags, timestamps, links, lists, tables and source blocks, styled as you type
- Folding and structure editing, with Emacs, Mac or Doom (Vim) keys
- Several files side by side in panes and tabs
- Changes made by other apps merged into your edits, with a sheet to resolve overlapping changes

AGENDA
- Scheduled items, deadlines and timestamps from all your files, by day
- A board that shows entries as a table or as kanban columns
- Habits with their consistency graph
- Events from the Calendar app alongside your entries

CAPTURE
- Capture templates with questions, as in Org
- Capture from a global keyboard shortcut, from Shortcuts, or from org-protocol links, so browser bookmarklets work unchanged

CLOCKING
- Clock in and out of entries, with the running clock in the menu bar
- Clock reports

AND MORE
- Search across file names, headings and text
- Table formulas and plots
- Emacs Lisp source blocks, run by orgstar's own interpreter, and tangling source blocks into files
- Export to HTML, Markdown, PDF, Word, RTF, plain text and iCalendar, and publishing projects
- Desktop and Notification Center widgets: Today, Up Next and Habits
- Spotlight search and Quick Look previews of .org files
- Import from Emacs: reads your Emacs or Doom configuration and carries over org settings, folders, capture templates, key bindings and agenda views
- Settings in plain text files you can keep with your dotfiles

ORGSTAR+
Editing, the agenda, capture, clocking, tables, search, and HTML and Markdown export are free. orgstar+, monthly, yearly or as a one-time lifetime purchase, adds:
- Running Emacs Lisp blocks and tangling
- PDF, Word and rich text export, and publishing
- Encrypted entries
- Org-roam nodes, daily notes and backlinks
- Widgets
- Calendar events and reminders in the agenda
- Shortcuts actions
orgstar+ bought on iPhone or iPad unlocks the Mac too, and the other way round.

### Keywords

org-mode,emacs,outline,todo,agenda,plain text,notes,tasks,gtd,planner,kanban,org file,clock,markdown

### What's New

orgstar is now on the Mac App Store. orgstar+ bought in the iPhone and iPad app unlocks it here too.

### App Review notes

- The app runs in the App Sandbox and starts no other programs. It reads and writes only folders and files the user chooses in an open panel or opens from Finder, and keeps security-scoped bookmarks to them.
- Code (guideline 2.5.2): source blocks the user writes in their own documents can be run, and only Emacs Lisp blocks run. They are evaluated by an interpreter inside the app; no code is downloaded, and nothing changes the app's features. Before a block runs, the app asks whether to run it; the user can let it remember a block they trust.
- com.apple.security.network.client: remote images in documents, attaching a file from a URL, MathJax in HTML and PDF export, and the App Store.
- com.apple.security.files.user-selected.executable: tangling writes source blocks to files in folders the user chose. A block with a :shebang header, such as a shell script, gets the executable bit (mode 0755), as Org mode sets it. The app never runs these files.
- com.apple.security.personal-information.calendars: Calendar events and reminders in the agenda, after the system asks.
- com.apple.security.application-groups: the widgets read the agenda from the app group.
- To try it: on the first launch, click Choose Folder… and pick any folder, or New Folder in iCloud Drive… to make one with a notes file. orgstar+ is in Settings (Command-comma) ▸ orgstar+, with Restore Purchases and the tips.

### TestFlight

Beta App Description: orgstar for the Mac, from the Mac App Store. An editor for Org mode files that reads and writes plain-text .org files in folders you choose.

What to Test: Add a folder, edit files, check the agenda, capture and clocking. Run an Emacs Lisp block and tangle a file. Try orgstar+ with a purchase or Restore Purchases, and the widgets.

Feedback email: help@krz.sh
