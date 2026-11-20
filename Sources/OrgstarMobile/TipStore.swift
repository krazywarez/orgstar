#if os(iOS)
import OrgApp
import StoreKit
import SwiftUI

/// Tips from the App Store. `ProStore`'s transaction listener finishes any that arrive later.
@MainActor @Observable
final class TipStore {
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchasingProductID: String?
    /// A failure, or a tip waiting for approval, shown in the section.
    private(set) var message: String?
    /// Set after a tip goes through; the thank-you alert clears it.
    var thanked = false

    func loadProducts() async {
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

    func purchase(_ product: Product) async {
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

/// Tips in About, for everyone, with or without orgstar+.
struct TipSection: View {
    @State private var store = TipStore()

    var body: some View {
        Section {
            if store.isLoading && store.products.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(store.products) { product in
                Button { Task { await store.purchase(product) } } label: {
                    HStack {
                        Text(product.displayName)
                        Spacer()
                        if store.purchasingProductID == product.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(product.displayPrice).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .disabled(store.purchasingProductID != nil)
            }
            if let message = store.message {
                Text(message).foregroundStyle(.secondary)
                if store.products.count < Tip.productIDs.count {
                    Button("Try Again") { Task { await store.loadProducts() } }.disabled(store.isLoading)
                }
            }
        } header: {
            Text("Support Development")
        } footer: {
            Text("Tips are one-time purchases that help pay for orgstar's development. They don't unlock anything.")
        }
        .task { await store.loadProducts() }
        .alert("Thank You", isPresented: $store.thanked) {
            Button("OK") {}
        } message: {
            Text("Your tip helps keep orgstar going.")
        }
    }
}
#endif
