import OrgPresentation
import Testing

struct PaletteTests {
    @Test func defaultPalettesAreTheDefaultTheme() throws {
        let light = try #require(ThemeSpec.palette("default-light", .light))
        let dark = try #require(ThemeSpec.palette("default-dark", .dark))
        #expect(light.colors == ThemeSpec.default.light && dark.colors == ThemeSpec.default.dark)
        #expect(light.name == "Default" && ThemeSpec.palettes(.light).first == light && ThemeSpec.palettes(.dark).first == dark)
        #expect(ThemeSpec.defaultPaletteID(.light) == "default-light" && ThemeSpec.defaultPaletteID(.dark) == "default-dark")
    }

    @Test func aPaletteIsFoundOnlyInItsAppearance() {
        #expect(ThemeSpec.palette("default-light", .dark) == nil)
        #expect(ThemeSpec.palette("nope", .light) == nil)
    }

    @Test func accentIsASlotTheDefaultLeavesToTheSystem() {
        #expect(ThemeSpec.slots.contains { $0.key == "accent" })
        #expect(ThemeSpec.systemDefaults.contains("accent"))
        #expect(ThemeSpec.default.light["accent"] == nil && ThemeSpec.default.dark["accent"] == nil)
    }

    @Test func everyPaletteHasExactlyTheSlotKeys() {
        let all = Set(ThemeSpec.slots.map(\.key))
        for palette in ThemeSpec.palettes(.light) + ThemeSpec.palettes(.dark) {
            let expected = palette.id.hasPrefix("default-") ? all.subtracting(ThemeSpec.systemDefaults) : all
            #expect(Set(palette.colors.keys) == expected, "\(palette.id): \(expected.symmetricDifference(palette.colors.keys))")
        }
    }
}
