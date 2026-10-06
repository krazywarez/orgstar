import Testing
@testable import OrgCore

struct FileSummaryTests {
    @Test func readsKeywordsTagsAndHeadings() {
        let summary = FileSummary("#+title: Notes\n#+AUTHOR: Me\n#+FILETAGS: :home:\n* TODO [#A] Fix the sink [1/2] :home:diy:\n** Buy parts\n")
        #expect(summary.title == "Notes" && summary.author == "Me" && summary.description == nil)
        #expect(summary.tags == ["home", "diy"])
        #expect(summary.headings == ["Fix the sink", "Buy parts"])
        #expect(FileSummary("plain\n").title == nil)
    }
}
