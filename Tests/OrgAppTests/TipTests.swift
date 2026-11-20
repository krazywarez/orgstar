import Testing
@testable import OrgApp

struct TipTests {
    @Test func productIDsMatchAppStoreConnectInOrder() {
        #expect(Tip.productIDs == [
            "sh.krz.orgstar.tip.small",
            "sh.krz.orgstar.tip.medium",
            "sh.krz.orgstar.tip.large",
        ])
    }

    @Test func productIDsAreNotOrgstarPlus() {
        // Tips must never count as an orgstar+ purchase.
        #expect(Tip.productIDs.allSatisfy { !$0.hasPrefix("sh.krz.orgstar.pro.") })
    }
}
