# Sparkle Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac build installed from the DMG or the cask learns about the next release and installs it, with Check for Updates… in the app menu and an automatic-checks setting.

**Architecture:** Sparkle 2 from its SwiftPM package, linked into the `Orgstar` target and copied into `Contents/Frameworks` by `scripts/build-app.sh`. The appcast is a static file in the manual's site, `docs/manual/appcast.xml`, served at `https://krz.gitbay.site/orgstar/appcast.xml` by `scripts/publish-docs.sh`; `scripts/release-mac.sh` signs the DMG with the EdDSA key, prepends the release to the appcast through a merge request on main, and publishes the manual. Nothing is served from anywhere new.

**Tech Stack:** Sparkle 2.7 (SPM binary target), `generate_keys` and `sign_update` from the package's `bin`, `xmllint`.

**Spec:** `docs/design.md`, Decisions ▸ Distribution ("Direct download (notarized, Sparkle) and Homebrew cask").

## Global constraints

- The app stays unsandboxed; Sparkle's XPC services are not used.
- Dev builds (`ORGSTAR_SIGN` unset, ad hoc) carry no feed URL, so they never check.
- Nothing is pushed to main directly: the appcast change goes in through a merge request, as the cask does.
- Release notes in the appcast are the same text `release-mac.sh` gives `gitbay release create --notes`.

## Decisions

| Question | Decision | Reason |
| --- | --- | --- |
| Feed host | The `pages` branch, beside the manual | Already published by a script; a fixed URL, unlike release assets which are per tag |
| Version Sparkle compares | `CFBundleVersion`, the commit count `release-mac.sh` already sets | Monotonic across releases; `sparkle:shortVersionString` shows the semver |
| Automatic checks | Sparkle's own first-run prompt, no `SUEnableAutomaticChecks` key | Asking once is the Sparkle default and needs no UI of our own |
| Delta updates | No | One DMG per release is enough at this size |
| Private key | The login keychain of the release Mac, where `generate_keys` puts it | `sign_update` finds it there; nothing in the repo |

## Review focus

- A dev build must not offer updates: without `SUFeedURL` the updater must not start, and the menu item must be disabled, not crash.
- The appcast must still validate after many releases: entries are prepended, never rewritten, and `xmllint` runs before the commit.
- `release-mac.sh` must upload the DMG before publishing the appcast, or a client can read an entry whose enclosure 404s.
- The `pages` publish replaces the whole branch, so the appcast has to live in `docs/manual`, not be written onto `pages` by hand.
- Signing: `codesign --verify --strict --deep` on the app must still pass with the framework inside, or notarization fails late.

---

### Task 1: Link Sparkle and bundle the framework

**Files:**
- Modify: `Package.swift` (dependencies; `Orgstar` target)
- Modify: `scripts/build-app.sh`

- [ ] Add the dependency and the product to the app target:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
// ...
.executableTarget(name: "Orgstar", dependencies: ["OrgApp", "OrgEditorAppKit", "OrgHighlight", .product(name: "Sparkle", package: "Sparkle")]),
```

- [ ] In `build-app.sh`, after copying the binary: copy the framework from the SwiftPM artifact and give the executable an rpath to it.

```sh
sparkle="$(find .build/artifacts -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -maxdepth 6 | head -1)"
[ -n "$sparkle" ] || { echo "Sparkle.framework not in .build/artifacts; run swift build first." >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Orgstar"
```

- [ ] Sign Sparkle's inner pieces before the app, with the same identity and flags (Sparkle's documented order), inside the final signing block:

```sh
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$fw/XPCServices/Installer.xpc" "$fw/XPCServices/Downloader.xpc" "$fw/Autoupdate" "$fw/Updater.app" "$app/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign "$sign" $sign_flags "$item"
done
```

- [ ] Add `SUFeedURL` and `SUPublicEDKey` to the generated Info.plist only when `sign` is not `-`:

```sh
if [ "$sign" != "-" ]; then
    feed_keys="<key>SUFeedURL</key><string>https://krz.gitbay.site/orgstar/appcast.xml</string><key>SUPublicEDKey</key><string>${ORGSTAR_ED_PUBLIC_KEY:?set ORGSTAR_ED_PUBLIC_KEY}</string>"
else
    feed_keys=""
fi
```

and `${feed_keys}` in the plist heredoc after `LSMinimumSystemVersion`. The public key is pasted into `scripts/release-mac.sh` as a default for `ORGSTAR_ED_PUBLIC_KEY` once Task 3 generates it.

- [ ] Verify: `sh scripts/build-app.sh`, then `otool -l .build/app/orgstar.app/Contents/MacOS/Orgstar | grep -A2 LC_RPATH` shows the Frameworks rpath, `open .build/app/orgstar.app` launches, and `codesign --verify --strict --deep .build/app/orgstar.app` passes.
- [ ] Commit "Link Sparkle and bundle its framework".

### Task 2: Check for Updates… and the setting

**Files:**
- Modify: `Sources/Orgstar/OrgstarApp.swift` (`AppDelegate` at line 151; `.commands`)
- Modify: `Sources/Orgstar/OrgstarApp.swift` (`SettingsView`, the General tab at line 551)

- [ ] In the app delegate, one controller for the process:

```swift
import Sparkle
let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```

Without a feed URL (dev builds) the updater logs that it can't start and `canCheckForUpdates` stays false; that is the intended dev behaviour.

- [ ] Menu item after About, following Sparkle's SwiftUI sample:

```swift
CommandGroup(after: .appInfo) {
    Button("Check for Updates…") { delegate.updater.updater.checkForUpdates() }
        .disabled(!delegate.updater.updater.canCheckForUpdates)
}
```

`canCheckForUpdates` is KVO-observable; wrap the updater in a small `@Observable` holder that observes it, so the button enables once the updater starts.

- [ ] Settings ▸ General: a toggle bound to `updater.automaticallyChecksForUpdates`, shown only when `canCheckForUpdates` is true, labelled "Check for updates automatically".
- [ ] Test by hand: a dev build shows the item disabled and no toggle; a `ORGSTAR_SIGN=<Developer ID>` build with a local feed (Task 4) shows both.
- [ ] Commit "Check for Updates… and automatic checks".

### Task 3: Keys and the appcast file

**Files:**
- Create: `docs/manual/appcast.xml`
- Create: `scripts/appcast-add.sh`
- Modify: `docs/manual/orgo.toml` only if orgo needs the file listed to copy it (check with `scripts/publish-docs.sh --dry-run` and `ls` of the built site; `favicon.svg` and `style.css` are copied today, so it should not)

- [ ] Generate the key pair once on the release Mac: `"$(find .build/artifacts -name generate_keys -type f | head -1)"`. The private key goes to the login keychain; paste the printed public key as the `ORGSTAR_ED_PUBLIC_KEY` default in `release-mac.sh`.
- [ ] The empty appcast:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>orgstar</title>
    <link>https://gitbay.org/krz/orgstar</link>
  </channel>
</rss>
```

- [ ] `scripts/appcast-add.sh <appcast> <version> <build> <dmg> <notes-file>`: runs `sign_update "$dmg"` (found under `.build/artifacts` like `generate_keys`), which prints `sparkle:edSignature="…" length="…"`, and inserts after `<link>…</link>` in the channel:

```xml
    <item>
      <title>orgstar VERSION</title>
      <link>https://gitbay.org/krz/orgstar/releases/tag/vVERSION</link>
      <sparkle:version>BUILD</sparkle:version>
      <sparkle:shortVersionString>VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <pubDate>RFC 2822 date</pubDate>
      <description><![CDATA[NOTES]]></description>
      <enclosure url="https://gitbay.org/krz/orgstar/releases/download/vVERSION/orgstar-VERSION.dmg" type="application/octet-stream" sparkle:edSignature="…" length="…"/>
    </item>
```

Insertion is a `sed`/`awk` on the first `</link>` after `<channel>`; the script refuses a version already present (`grep -q "<sparkle:shortVersionString>$version<"`) and ends with `xmllint --noout "$appcast"`.

- [ ] Verify with a throwaway copy: `scripts/appcast-add.sh /tmp/a.xml 0.2.0 365 .build/release/orgstar-0.2.0.dmg notes.txt` twice; the second run exits non-zero naming the version.
- [ ] Commit "Appcast file and appcast-add.sh".

### Task 4: Release script and cask

**Files:**
- Modify: `scripts/release-mac.sh`
- Modify: `packaging/orgstar.rb`

- [ ] After `gitbay release asset add` and before the tap section, add the appcast entry through a merge request, mirroring the tap block:

```sh
notes="Universal (Apple silicon and Intel), macOS 26 or later. Notarized."
printf '%s\n' "$notes" > "$out/notes.txt"
branch="appcast-$version"
git switch -q -c "$branch"
sh scripts/appcast-add.sh docs/manual/appcast.xml "$version" "$build" "$dmg" "$out/notes.txt"
git add docs/manual/appcast.xml
git commit -q -m "Appcast for $version"
git push -q -u origin "$branch"
mr="$(gitbay mr create --source "$branch" --target main --title "Appcast for $version" --body "Sparkle entry for orgstar $version." --json | sed -n 's/.*"number":\([0-9]*\).*/\1/p')"
gitbay mr merge "$mr" --strategy ff
git switch -q main && git pull -q --ff-only && git branch -d "$branch" && git push -q origin --delete "$branch"
sh scripts/publish-docs.sh
```

`$notes` replaces the literal string already passed to `gitbay release create`. With `ORGSTAR_PUBLISH=0` the script runs `appcast-add.sh` on a copy under `$out` and prints the entry instead, so a dry run shows the signature.

- [ ] Cask: add `auto_updates true` after `desc`, so `brew upgrade` leaves updating to the app.
- [ ] End-to-end check before the first real release: build with a Developer ID, point a running copy at a local appcast with `defaults write sh.krz.orgstar SUFeedURL file:///tmp/a.xml` (Sparkle reads the feed from user defaults ahead of Info.plist), Check for Updates… offers the entry and installs the DMG; then `defaults delete sh.krz.orgstar SUFeedURL`.
- [ ] Manual: `docs/manual/guide/01-files-and-folders.org` or `install.org` gets a paragraph on updates (menu item, the setting, that the cask has `auto_updates`).
- [ ] Commit "Release script writes the appcast; cask auto_updates".
