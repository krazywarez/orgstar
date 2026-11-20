#if APPSTORE
import OrgApp
import StoreKit
import SwiftUI

/// orgstar+ from the App Store: status, plans with their prices and renewal terms, restoring,
/// managing a subscription, and tips.
struct StoreForm: View {
    /// The feature that led here, if any.
    var feature: ProFeature?
    /// Whether to show the tips section, which the paywall leaves out.
    var showsTips = true
    private var store: ProStore { .shared }
    private var access: ProAccess { .shared }

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://krz.sh/privacy/orgstar/")!
    static let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.orange.gradient, in: .rect(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let feature, !access.isUnlocked {
                            Text("\(feature.storeTitle) needs orgstar+.").font(.headline)
                        } else {
                            Text(verbatim: "orgstar+").font(.headline)
                        }
                        Text(status).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(ProFeature.macFeatures) { feature in
                    Label(feature.storeTitle, systemImage: feature.systemImage)
                }
            } header: {
                Text("Included in orgstar+")
            } footer: {
                Text("Editing, the agenda, capture, clocking, tables and search stay free.").settingsFooter()
            }
            if store.activeProductID != ProStore.lifetime {
                Section {
                    if store.isLoading && store.products.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(store.products) { product in plan(product) }
                    if !store.isLoading && store.message != nil && store.products.count < ProStore.productIDs.count {
                        Button("Try Again") { Task { await store.loadProducts() } }
                    }
                } header: {
                    Text("Choose a plan")
                } footer: {
                    Text("Subscriptions renew automatically until cancelled in your Apple Account settings, at least 24 hours before the period ends.")
                        .settingsFooter()
                }
            }
            Section {
                HStack {
                    Button("Restore Purchases") { Task { await store.restore() } }.disabled(store.busy)
                    if store.activeProductID == ProStore.monthly || store.activeProductID == ProStore.yearly {
                        Link("Manage Subscription…", destination: Self.subscriptionsURL)
                    }
                    Spacer()
                    Link("Terms of Use", destination: Self.termsURL)
                    Link("Privacy Policy", destination: Self.privacyURL)
                }
                if let message = store.message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            if showsTips {
                StoreTipSection()
            }
        }
        .formStyle(.grouped)
        .task { await store.loadProducts() }
    }

    /// One plan: its name, an optional savings tag, what it bills, and a button with its price.
    private func plan(_ product: Product) -> some View {
        LabeledContent {
            Button(price(product)) { Task { await store.buy(product) } }
                .monospacedDigit()
                .disabled(store.busy || product.id == store.activeProductID)
        } label: {
            HStack(spacing: 6) {
                Text(product.displayName)
                if let percent = savings(product) {
                    Text("Save \(percent)%")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.gradient, in: .capsule)
                }
            }
            Text(detail(product))
        }
    }

    private func detail(_ product: Product) -> String {
        if product.id == store.activeProductID { return String(localized: "Current plan") }
        switch product.id {
        case ProStore.monthly: return String(localized: "Billed monthly")
        case ProStore.yearly:
            let perMonth = (product.price / 12).formatted(product.priceFormatStyle)
            return String(localized: "\(perMonth) a month, billed yearly")
        default: return String(localized: "One payment, no subscription")
        }
    }

    /// The price with its billing period.
    private func price(_ product: Product) -> String {
        switch product.subscription?.subscriptionPeriod.unit {
        case .month: String(localized: "\(product.displayPrice) / month")
        case .year: String(localized: "\(product.displayPrice) / year")
        default: product.displayPrice
        }
    }

    private func savings(_ product: Product) -> Int? {
        guard product.id == ProStore.yearly,
              let monthly = store.products.first(where: { $0.id == ProStore.monthly })
        else { return nil }
        return ProStore.yearlySavings(yearly: product.price, monthly: monthly.price)
    }

    private var status: String {
        guard access.isUnlocked else { return String(localized: "Power features and Apple integrations, on top of everything that stays free.") }
        return store.activeProductID == ProStore.lifetime
            ? String(localized: "You own orgstar+. Thank you for supporting orgstar.")
            : String(localized: "Your orgstar+ subscription is active. Thank you for supporting orgstar.")
    }
}

/// Tips, for everyone, with or without orgstar+.
struct StoreTipSection: View {
    @State private var store = TipStore()

    var body: some View {
        Section {
            if store.isLoading && store.products.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(store.products) { product in
                LabeledContent(product.displayName) {
                    if store.purchasingProductID == product.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(product.displayPrice) { Task { await store.purchase(product) } }
                            .monospacedDigit()
                            .disabled(store.purchasingProductID != nil)
                    }
                }
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
                .settingsFooter()
        }
        .task { await store.loadProducts() }
        .alert("Thank You", isPresented: $store.thanked) {
            Button("OK") {}
        } message: {
            Text("Your tip helps keep orgstar going.")
        }
    }
}

/// Shown when a Pro feature is used without Pro.
struct StorePaywallSheet: View {
    let feature: ProFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            StoreForm(feature: feature, showsTips: false)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520, height: 600)
        .onChange(of: ProAccess.shared.isUnlocked) { _, unlocked in if unlocked { dismiss() } }
    }
}

extension ProFeature {
    /// The title in the App Store build, which runs Emacs Lisp blocks natively.
    var storeTitle: String {
        self == .babel ? String(localized: "Run Emacs Lisp blocks and tangle") : title
    }
}
#endif
