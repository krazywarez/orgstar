#if os(iOS)
import OrgApp
import StoreKit
import SwiftUI
import UIKit

/// orgstar+'s gold, for its banner in Settings and its screen.
extension ShapeStyle where Self == LinearGradient {
    static var plusGold: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.0, green: 0.84, blue: 0.36), Color(red: 0.86, green: 0.6, blue: 0.12)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The gold star that marks orgstar+.
struct PlusBadge: View {
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.plusGold, in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

/// What orgstar+ includes, its prices, and buying, restoring or managing it.
struct ProScreen: View {
    /// The feature that led here, if any.
    var feature: ProFeature?
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false
    private var store: ProStore { .shared }
    private var access: ProAccess { .shared }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    PlusBadge(size: 76)
                        .shadow(color: .orange.opacity(0.35), radius: 14, y: 6)
                    Text(verbatim: "orgstar+").font(.largeTitle.bold())
                    if let feature, !access.isUnlocked {
                        Text("\(feature.title) needs orgstar+.").font(.headline)
                    }
                    Text(status).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)
            Section {
                ForEach(ProFeature.allCases) { feature in
                    Label {
                        Text(feature.title)
                    } icon: {
                        Image(systemName: feature.systemImage).foregroundStyle(.plusGold)
                    }
                }
            } header: {
                Text("Included in orgstar+")
            } footer: {
                Text("Editing, the agenda, capture, clocking, tables and search stay free.")
            }
            if access.grant != .grandfathered, store.activeProductID != ProStore.lifetime {
                Section {
                    if store.products.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(store.products) { product in
                        Button { Task { await store.buy(product) } } label: { plan(product) }
                            .tint(.primary)
                            .disabled(store.busy || product.id == store.activeProductID)
                    }
                } header: {
                    Text("Choose a plan")
                } footer: {
                    Text("Subscriptions renew automatically until cancelled in your Apple Account settings, at least 24 hours before the period ends.")
                }
            }
            Section {
                Button("Restore Purchases") { Task { await store.restore() } }.disabled(store.busy)
                if store.activeProductID == ProStore.monthly || store.activeProductID == ProStore.yearly {
                    Button("Manage Subscription") { managing = true }
                }
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy Policy", destination: URL(string: "https://krz.sh/privacy/orgstar/")!)
            }
            if let message = store.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(Text(verbatim: "orgstar+"))
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $managing)
        .task { await store.loadProducts() }
    }

    /// One plan: its name, an optional savings tag, what it bills, and its price.
    private func plan(_ product: Product) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(product.displayName).font(.headline)
                    if let percent = savings(product) {
                        Text("Save \(percent)%")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.plusGold, in: .capsule)
                    }
                }
                detail(product).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(product.displayPrice + period(product))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }

    private func detail(_ product: Product) -> Text {
        if product.id == store.activeProductID { return Text("Current plan") }
        switch product.id {
        case ProStore.monthly: return Text("Billed monthly")
        case ProStore.yearly:
            let perMonth = (product.price / 12).formatted(product.priceFormatStyle)
            return Text("\(perMonth) a month, billed yearly")
        default: return Text("One payment, no subscription")
        }
    }

    /// How much the yearly plan saves against twelve months, in whole percent.
    private func savings(_ product: Product) -> Int? {
        guard product.id == ProStore.yearly,
              let monthly = store.products.first(where: { $0.id == ProStore.monthly }), monthly.price > 0
        else { return nil }
        let ratio = NSDecimalNumber(decimal: product.price / (monthly.price * 12)).doubleValue
        let percent = Int((1 - ratio) * 100)
        return percent > 0 ? percent : nil
    }

    private var status: LocalizedStringKey {
        switch access.grant {
        case .grandfathered: "Included, because you downloaded orgstar before orgstar+ existed. Thank you."
        case .purchase: store.activeProductID == ProStore.lifetime ? "You own orgstar+. Thank you for supporting orgstar." : "Your orgstar+ subscription is active. Thank you for supporting orgstar."
        case .license, nil: "Power features and Apple integrations, on top of everything that stays free."
        }
    }

    private func period(_ product: Product) -> String {
        switch product.subscription?.subscriptionPeriod.unit {
        case .month: " / month"
        case .year: " / year"
        default: ""
        }
    }
}

/// The paywall as a sheet, with a close button.
struct ProSheet: View {
    let feature: ProFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProScreen(feature: feature)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onChange(of: ProAccess.shared.isUnlocked) { _, unlocked in if unlocked { dismiss() } }
    }
}
#endif
