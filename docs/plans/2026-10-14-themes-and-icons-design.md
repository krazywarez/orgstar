# Built-in Themes and Alternate App Icons

## Goal

Users who don't write TOML pick from a list of built-in color themes, one for the light appearance and one for the dark, on the Mac and on iOS. Users pick an app icon from a list of alternates to suit their taste. Themes and icons are separate choices.

## Scope

In:

- 16 built-in palettes (7 light, 9 dark), selectable per appearance in Settings on both platforms.
- An `accent` theme slot that tints SwiftUI controls.
- 13 app icons, each with default, dark and tinted variants for the system icon styles.
- iOS: alternate app icons through `setAlternateIconName`.
- Mac: the selected icon shown in the Dock while the app runs; the bundle's icon compiled from an asset catalog. actool keeps only the default rendition for macOS, so macOS derives the dark and tinted styles itself.

Out:

- Changing the Mac app's icon on disk (Finder, Dock after quit).
- Tying icons to themes.
- Theming the Watch app or its icon.
- A theme editor.

## Themes

### Palettes

Each palette covers one appearance and is defined in Swift, in `Sources/OrgPresentation/Palettes.swift`, by 12 named colors (`ThemeSpec.Roles`: `bg`, `alt`, `fg`, `dim`, `red`, `orange`, `yellow`, `green`, `cyan`, `blue`, `purple`, `accent`). One table, `Roles.slots`, maps those colors onto every slot, so each palette is a dozen hex values, and the same table keeps every palette's slots in step when slots are added. Palettes are not SwiftPM resources: `OrgPresentation` is linked into the widget, Quick Look and Spotlight extensions, and a resource bundle would have to be copied into each by `build-app.sh` and the Xcode project.

| Light | Dark |
| --- | --- |
| `default-light` Default | `default-dark` Default |
| `solarized-light` Solarized Light | `solarized-dark` Solarized Dark |
| `gruvbox-light` Gruvbox Light | `gruvbox-dark` Gruvbox Dark |
| `modus-operandi` Modus Operandi | `modus-vivendi` Modus Vivendi |
| `catppuccin-latte` Catppuccin Latte | `catppuccin-mocha` Catppuccin Mocha |
| `tomorrow` Tomorrow | `nord` Nord |
| `paper` Paper | `dracula` Dracula |
| | `tokyo-night` Tokyo Night |
| | `doom-one` doom-one |

`default-light` and `default-dark` are `ThemeSpec.default`'s light and dark colors, unchanged and not through `Roles`. They leave `ThemeSpec.systemDefaults` and `accent` unset, so the default look does not change. Every other palette sets every slot, the sidebar, modeline and agenda backgrounds included.

Where a ported palette's color fails the contrast test on its background, the palette uses a darker or lighter value of the same hue; the palette's comment in `Palettes.swift` lists those. Each ported palette's upstream license is recorded in `THIRD_PARTY.org`. Paper is original.

`ThemeSpec.palettes(_ appearance:) -> [Palette]` lists the palettes in the table's order. `Palette` has `id`, `name`, `appearance` and `colors: [String: RGBA]`.

### Settings

Two entries in `UserConfig`'s `Setting` registry, section `theme`:

| Key | Defaults key | Fallback |
| --- | --- | --- |
| `light-theme` | `themeLight` | `"default-light"` |
| `dark-theme` | `themeDark` | `"default-dark"` |

An id that isn't a bundled palette of that appearance adds the problem `config.toml: unknown light-theme <id>` (or `dark-theme`) and uses the Default palette.

### Layering

`UserConfig.theme` builds the base from the two palettes: `light` = the light palette's colors, `dark` = the dark palette's colors. Then `theme-file`, then `config.toml`'s `[theme]`, `[theme.light]`, `[theme.dark]`, `[theme.todo]` and `[theme.category]`, as today. With both settings at Default the result equals today's.

`default-theme.toml` is still written at launch from `ThemeSpec.default`.

### Accent

`accent` is added to `ThemeSpec.slots` ("buttons, toggles and selection in lists; unset: the system's") and to `systemDefaults`. When set it is applied with `.tint()`:

- Mac: on each scene root that sets `.environment(\.orgTheme, …)` in `OrgstarApp.swift`.
- iOS: on the root tab view.

Existing `.tint(` call sites are left alone.

### Copy to Config Folder

Writes the two selected palettes as `my-theme.toml` into the configuration folder, `[theme.light]` from the light palette and `[theme.dark]` from the dark, every slot written out, and sets `theme-file` to it. An existing file of that name is not overwritten; the button reports it instead.

### Picker UI

Mac, Settings ▸ Appearance, a new first section "Theme":

- Light and Dark rows, each a menu `Picker` of that appearance's palettes, each item with a swatch strip of `background`, `foreground`, `heading-1`, `todo` and `accent`.
- Copy to Config Folder.
- Footer: colors in `config.toml` and the theme file apply on top.

iOS, Settings tab, a new section "Appearance":

- Light Theme and Dark Theme rows, each pushing a list of palettes. Each row is a card of sample Org text (a heading, a TODO keyword, a tag, a link, a timestamp) styled with that palette through `MobileTheme`.
- The choice is written to the configuration folder's `config.toml`, so it syncs with the Mac.
- "In use ▸ Theme" shows `<light name> / <dark name>`, plus the theme file's name when set.

The choice applies at once on both platforms; the open editor is the preview.

### Widgets

Widgets take colors from the `ThemeSpec` handed to `WidgetData` and `AgendaSnapshot`, so they follow the palettes. A theme change triggers the same widget reload a config change does now.

## Icons

### Catalog

| Id | Look |
| --- | --- |
| `default` | Gold ✱ and white bars on blue-violet (today's icon) |
| `midnight` | Gold ✱ on near-black |
| `paper` | Dark ✱ and bars on off-white |
| `org` | Gold ✱ on Org mode's green-teal |
| `sunset` | White ✱ on orange-to-pink |
| `forest` | Cream ✱ on deep green |
| `mono` | White ✱ on graphite |
| `rainbow` | White ✱ on a rainbow gradient |
| `outline` | Line drawing of the ✱ and bars on white |
| `terminal` | Green ✱ and bars on black |
| `unicorn` | White unicorn head in profile on green-teal, the gold ✱ at the horn's tip |
| `unicorn-night` | The unicorn on deep indigo, silver ✱ |
| `unicorn-pastel` | The unicorn on pink-to-lavender |

The unicorn is drawn for orgstar in `make-icon.swift`; the Org mode logo is not copied.

### Generation

`scripts/make-icon.swift` takes a variant table: background gradient, glyph, glyph color, bar color, and a drawing style (`filled`, `outline`, `unicorn`). For each icon it writes:

- default: the icon as today.
- dark: the glyph and bars on a transparent background, which the system places on its dark background.
- tinted: a grayscale glyph and bars on a transparent background, which the system tints.

Outputs:

- `ios/Orgstar/Assets.xcassets/AppIcon.appiconset` and `AppIcon-<Id>.appiconset` for the others, each a 1024-pixel PNG per variant, with `appearances` entries `luminosity: dark` and `luminosity: tinted` in `Contents.json`.
- `packaging/AppIcons.xcassets` for the Mac: the `AppIcon` set only, at the Mac's sizes, compiled by `build-app.sh`.
- Previews: on iOS an `IconPreview-<id>` image set (256 pixels, light and dark appearances) in `Assets.xcassets`; on the Mac `packaging/IconPreviews/<id>-light.png` and `<id>-dark.png` (512 pixels), which `build-app.sh` copies into `Contents/Resources/IconPreviews/`, loaded with `Bundle.main`.

The generated files are committed; `swift scripts/make-icon.swift` is run by hand when the icons change.

### iOS

- The Xcode project sets `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` for the app target, so every `AppIcon-*` set is an alternate.
- Settings tab, "Appearance" section: an App Icon row pushing a grid of previews. Tapping one calls `UIApplication.shared.setAlternateIconName` (`nil` for `default`); the system's confirmation alert shows. The selection reflects `UIApplication.shared.alternateIconName`, the only source of truth.
- The choice is per device and is not written to `config.toml`.

### Mac

- `scripts/build-app.sh` compiles `AppIcons.xcassets` with `actool --app-icon AppIcon` into `Contents/Resources/Assets.car` and sets `CFBundleIconName = AppIcon`, replacing `iconutil`, the `.icns` and `CFBundleIconFile` (the app requires macOS 26).
- Settings ▸ Appearance: an App Icon row with a grid of previews. The choice is kept in `UserDefaults` (`appIcon`), per Mac, not in `config.toml`.
- At launch and on change, a choice other than `default` sets `NSApp.applicationIconImage` to its light or dark preview by `NSApp.effectiveAppearance`, and again when the appearance changes. `default` sets it to `nil`. The footer says the icon shows in the Dock while orgstar runs.

## Testing

- `OrgPresentationTests`:
  - Each bundled palette parses with no problems, has a known `appearance`, and sets every slot outside `systemDefaults` (Default palettes) or every slot (the others).
  - Contrast against `background`: `foreground` and `table` at least 4.5:1; headings, TODO classes, `link`, `timestamp`, `code` and `syntax-*` at least 3:1.
  - Every palette's `colors` has exactly the keys of `ThemeSpec.slots` (Default palettes: minus `systemDefaults`).
- `OrgAppTests` (`UserConfig.theme`):
  - Default/Default with no overrides equals today's output.
  - `light-theme = "nord"` (wrong appearance) and an unknown id give a problem and Default.
  - `theme-file` and `[theme.dark]` still layer over the chosen palettes.
- Icons: manual check on an iOS 26 device and macOS 26 of each icon in default, dark and tinted styles.

## Risks

- Whether macOS 26 applies `luminosity` appearances from an `.appiconset` compiled by `actool` to the bundle's icon. Checked first in the plan. If it doesn't, the Mac bundle icon uses only the default variant and the system derives dark and tinted versions itself.
- iOS alternate icons with dark and tinted appearances require the per-set `appearances` entries to compile into the alternates. Checked on a device before the other 12 icons are drawn.
