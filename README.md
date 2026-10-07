# Orgstar

A native macOS editor for org-mode files, with an iOS app for iPhone and iPad.

The files are the source of truth: Orgstar edits them in place and leaves
every byte you didn't change as it was, so Emacs and sync tools can work on
the same folder.

Status: macOS v1, design phases 1–6: editing with Emacs, Mac and Doom keys,
agenda, table formulas, Babel and tangling, export, capture, clocking, board,
themes and buffers. Owed: the M1 Air gate run and the VoiceOver check. iOS
(phase 7): the editor, agenda, capture, search, clocking, reminders, export
and tangling, Simulator builds only so far.

## Build and run

Requires macOS 26 and Xcode 27 (Swift 6.2 tools).

```sh
scripts/build-app.sh          # builds .build/app/Orgstar.app, signed ad hoc
open .build/app/Orgstar.app
```

Add a folder with File > Add Folder… (⇧⌘O). ⌘P opens a file by name, ⇧⌘F
searches, ⇧⌘A shows the agenda. In the editor, TAB on a heading cycles its
folding and Shift-TAB cycles the whole file. Orgstar opens `.org` files from
Finder once the app has been launched.

C-c C-v t tangles the file's source blocks into the files their `:tangle`
header names, as `org-babel-tangle` does.

`org-protocol://capture?template=…&url=…&title=…&body=…` and
`org-protocol://store-link?url=…&title=…` links work as in Emacs, so browser
bookmarklets written for org-protocol work unchanged. Shortcuts has a
"Capture to Orgstar" action that files text with a capture template.

The iOS app (iOS 26) builds for the Simulator:

```sh
scripts/build-ios-app.sh      # builds .build/ios-app/Orgstar.app
xcrun simctl install booted .build/ios-app/Orgstar.app
```

On iOS, Orgstar in the share sheet takes a page or text with a template; the
app opens its capture sheet with it when it's next active. Shortcuts has the
same "Capture to Orgstar" action as on the Mac.

Settings live in `~/.config/orgstar/config.toml` (Orgstar ▸ Edit Config File),
with keys in `keymap.toml` and capture templates in `capture.toml` beside it.
Settings ▸ General ▸ Import from Emacs reads an existing Emacs or Doom
configuration.

```sh
swift test                                            # all tests
ORGSTAR_GATES=1 swift test -c release --filter GateTests   # performance gates
```

`docs/design.md` is the design; `docs/plans/` has one plan per piece of work.

License: 0BSD.
