import Testing
@testable import OrgCore

struct SourceTextTests {
    @Test func plainUTF8() {
        let source = SourceText(bytes: Array("* a\n".utf8))
        #expect(source.text == "* a\n")
        #expect(!source.hasBOM)
        #expect(source.isEditable)
    }

    @Test func bomIsStrippedAndRestored() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("x\n".utf8)
        let source = SourceText(bytes: bytes)
        #expect(source.hasBOM)
        #expect(source.text == "x\n")
        #expect(source.encode(source.text) == bytes)
        #expect(source.encode("y\n") == [0xEF, 0xBB, 0xBF] + Array("y\n".utf8))
    }

    @Test func crlfAndMixedEndingsSurvive() {
        let bytes = Array("a\r\nb\nc\r\n".utf8)
        let source = SourceText(bytes: bytes)
        #expect(source.encode(source.text) == bytes)
    }

    @Test func invalidUTF8IsReadOnlyAndUnchanged() {
        let bytes: [UInt8] = [0x61, 0xFF, 0x0A]
        let source = SourceText(bytes: bytes)
        #expect(!source.isValidUTF8)
        #expect(!source.isEditable)
        #expect(source.encode(source.text) == bytes)
    }

    @Test func nonBMPAndCombiningSurvive() {
        let bytes = Array("😀 e\u{301}\n".utf8)
        let source = SourceText(bytes: bytes)
        #expect(source.encode(source.text) == bytes)
    }
}
