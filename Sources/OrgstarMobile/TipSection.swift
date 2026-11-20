#if os(iOS)
import OrgApp
import StoreKit
import SwiftUI

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
