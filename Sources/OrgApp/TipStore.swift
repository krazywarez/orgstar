#if canImport(StoreKit)
import Foundation
import Observation
import StoreKit

/// Tips from the App Store. `ProStore`'s transaction listener finishes any that arrive later.
@MainActor @Observable
public final class TipStore {
    public private(set) var products: [Product] = []
    public private(set) var isLoading = false
    public private(set) var purchasingProductID: String?
    /// A failure, or a tip waiting for approval, shown in the section.
    public private(set) var message: String?
    /// Set after a tip goes through; the thank-you alert clears it.
    public var thanked = false

    public init() {}

    public func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Tip.productIDs)
            products = Tip.productIDs.compactMap { id in fetched.first { $0.id == id } }
            if products.count < Tip.productIDs.count {
                message = String(localized: "Some tips aren't available from the App Store right now.")
            }
        } catch {
            products = []
            message = String(localized: "The App Store can't be reached right now.")
        }
    }

    public func purchase(_ product: Product) async {
        guard purchasingProductID == nil else { return }
        purchasingProductID = product.id
        message = nil
        defer { purchasingProductID = nil }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                thanked = true
            case .success(.unverified):
                message = String(localized: "The App Store couldn't verify the purchase.")
            case .pending:
                message = String(localized: "The tip is waiting for approval.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = String(localized: "The purchase didn't go through. \(error.localizedDescription)")
        }
    }
}
#endif
