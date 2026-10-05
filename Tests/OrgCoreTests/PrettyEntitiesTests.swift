import Testing
@testable import OrgCore

struct PrettyEntitiesTests {
    @Test func entitiesAndChainedScripts() {
        let runs = PrettyEntities.runs(in: "\\alpha + \\beta{} = x_{1}^{2} \\to", subSuperscriptsNeedBraces: true)
        #expect(runs == [
            .entity(range: 0..<6, display: "α"),
            .entity(range: 9..<16, display: "β"),
            .entity(range: 29..<32, display: "→"),
            .script(markers: [20..<21, 21..<22, 23..<24], body: 22..<23, superscript: false),
            .script(markers: [24..<25, 25..<26, 27..<28], body: 26..<27, superscript: true),
        ])
        #expect(PrettyEntities.runs(in: "snake_case", subSuperscriptsNeedBraces: true).isEmpty)
        #expect(PrettyEntities.runs(in: "a_b", subSuperscriptsNeedBraces: false) == [.script(markers: [1..<2], body: 2..<3, superscript: false)])
    }
}
