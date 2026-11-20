#if APPSTORE
import OrgApp
import StoreKit
import SwiftUI

// TODO(M1.6): the full Mac StoreKit UI (plans with per-period prices and renewal terms,
// Manage Subscription, Terms and Privacy, Tips) replaces these two views, keeping their names.

/// orgstar+ from the App Store: status, plans, and restoring.
struct StoreForm: View {
    private var store: ProStore { .shared }
    private var access: ProAccess { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("orgstar+", value: access.isUnlocked ? String(localized: "Unlocked") : String(localized: "Not purchased"))
            }
            if !access.isUnlocked {
                Section {
                    ForEach(store.products, id: \.id) { product in
                        LabeledContent(product.displayName) {
                            Button(product.displayPrice) { Task { await store.buy(product) } }
                                .disabled(store.busy)
                        }
                    }
                    Button("Restore Purchases") { Task { await store.restore() } }
                        .disabled(store.busy)
                    if let message = store.message { Text(message).foregroundStyle(.secondary) }
                }
            }
            Section("Included in orgstar+") {
                ForEach(ProFeature.macFeatures) { feature in
                    Label(feature.title, systemImage: feature.systemImage)
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.loadProducts() }
    }
}

/// Shown when a Pro feature is used without Pro.
struct StorePaywallSheet: View {
    let feature: ProFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("\(feature.title) needs orgstar+", systemImage: feature.systemImage)
                .font(.headline)
                .padding([.horizontal, .top], 20)
            StoreForm()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 520)
        .onChange(of: ProAccess.shared.isUnlocked) { _, unlocked in if unlocked { dismiss() } }
    }
}
#endif
