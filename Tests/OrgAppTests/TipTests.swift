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

#if canImport(StoreKit)
@MainActor
struct ProStoreTests {
    @Test func productIDsAreOrgstarPlusAndNotTips() {
        #expect(ProStore.productIDs == [
            "sh.krz.orgstar.pro.monthly",
            "sh.krz.orgstar.pro.yearly",
            "sh.krz.orgstar.pro.lifetime",
        ])
        #expect(Set(ProStore.productIDs).isDisjoint(with: Tip.productIDs))
    }

    @Test func grandfathersOnlyOnIOS() {
        #if os(iOS)
        #expect(ProStore.grandfathers)
        #else
        #expect(!ProStore.grandfathers)
        #endif
    }
}
#endif
