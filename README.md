# Orgstar

A native macOS editor for org-mode files. iOS later.

The files are the source of truth: Orgstar edits them in place and leaves
every byte you didn't change as it was, so Emacs and sync tools can work on
the same folder.

Status: phase 1 (parser, workspace, read-only viewer).

## Build and run

Requires macOS 26 and Xcode 27 (Swift 6.2 tools).

```sh
scripts/build-app.sh          # builds .build/app/Orgstar.app, signed ad hoc
open .build/app/Orgstar.app
```

Add a folder with File > Add Folder… (⇧⌘O). ⌘P opens a file by name, ⇧⌘F
searches. In the editor, TAB on a heading cycles its folding and Shift-TAB
cycles the whole file.

```sh
swift test                                            # all tests
ORGSTAR_GATES=1 swift test -c release --filter GateTests   # performance gates
```

`docs/design.md` is the design; `docs/plans/` has one plan per piece of work.

License: 0BSD.
