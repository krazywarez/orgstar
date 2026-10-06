import Testing
@testable import OrgDocument

struct DiffTests {
    @Test func diffsLines() {
        let diff = lineDiff(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        #expect(diff == [
            DiffLine(kind: .same, text: "a\n"), DiffLine(kind: .removed, text: "b\n"), DiffLine(kind: .added, text: "B\n"),
            DiffLine(kind: .same, text: "c\n"), DiffLine(kind: .added, text: "d\n"),
        ])
    }

    @Test func mergesWithMarkers() {
        let merged = mergeWithMarkers(base: "a\nb\nc\nd\n", ours: "a\nB1\nc\nd\nmine\n", theirs: "x\na\nB2\nc\nd\n", oursLabel: "mine", theirsLabel: "disk")
        #expect(merged == "x\na\n<<<<<<< mine\nB1\n=======\nB2\n>>>>>>> disk\nc\nd\nmine\n")
        let twoWay = mergeWithMarkers(base: nil, ours: "a\nb\n", theirs: "a\nc", oursLabel: "file", theirsLabel: "copy")
        #expect(twoWay == "a\n<<<<<<< file\nb\n=======\nc\n>>>>>>> copy\n")
    }
}
