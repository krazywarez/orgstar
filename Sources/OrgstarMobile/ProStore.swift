#if os(iOS)
import OrgApp
import StoreKit
import SwiftUI
import UIKit

/// orgstar Pro from the App Store: a monthly or yearly subscription, or a lifetime purchase. It
/// keeps `ProAccess.shared` current; installs from before Pro keep it without buying.
@MainActor @Observable
final class ProStore {
    static let shared = ProStore()

    static let monthly = "sh.krz.orgstar.pro.monthly"
    static let yearly = "sh.krz.orgstar.pro.yearly"
    static let lifetime = "sh.krz.orgstar.pro.lifetime"
    static let productIDs = [monthly, yearly, lifetime]

    private(set) var products: [Product] = []
    private(set) var activeProductID: String?
    private(set) var busy = false
    var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {}

    /// Starts listening for transactions and checks what's owned. Call once at launch.
    func start() {
        guard updates == nil else { return }
        updates = Task.detached(priority: .background) {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await ProStore.shared.refresh()
            }
        }
        Task { await refresh() }
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = Self.productIDs.compactMap { id in fetched.first { $0.id == id } }
        } catch {
            message = "The App Store can't be reached right now."
        }
    }

    /// Sets Pro from the current entitlements, or from the original download predating Pro.
    func refresh() async {
        var active: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if active == nil || transaction.productID == Self.lifetime { active = transaction.productID }
        }
        activeProductID = active
        if active != nil {
            ProAccess.shared.set(.purchase)
        } else if await Self.predatesPro() {
            ProAccess.shared.set(.grandfathered)
        } else if ProAccess.shared.grant != .grandfathered {
            // A cached grandfathered grant survives the App Store being unreachable.
            ProAccess.shared.set(nil)
        }
    }

    /// Whether this Apple Account first downloaded orgstar before Pro. Only the production App
    /// Store reports real original versions; sandbox and Xcode always say "1.0".
    private static func predatesPro() async -> Bool {
        guard case .verified(let app) = try? await AppTransaction.shared, app.environment == .production else { return false }
        return Grandfathering.predatesPro(originalBuild: app.originalAppVersion)
    }

    func buy(_ product: Product) async {
        busy = true
        defer { busy = false }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh()
            case .success(.unverified):
                message = "The App Store couldn't verify the purchase."
            case .pending:
                message = "The purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through. \(error.localizedDescription)"
        }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            if !ProAccess.shared.isUnlocked { message = "No orgstar Pro purchase was found for this Apple Account." }
        } catch {
            message = "Restore didn't finish. \(error.localizedDescription)"
        }
    }
}

/// What Pro includes, its prices, and buying, restoring or managing it.
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
                VStack(alignment: .leading, spacing: 6) {
                    if let feature, !access.isUnlocked {
                        Text("\(feature.title) needs orgstar Pro.").font(.headline)
                    }
                    Text(status).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(ProFeature.allCases) { Label($0.title, systemImage: $0.systemImage) }
            } header: {
                Text("Included in Pro")
            } footer: {
                Text("Editing, the agenda, capture, clocking, tables and search stay free.")
            }
            if access.grant != .grandfathered, store.activeProductID != ProStore.lifetime {
                Section {
                    if store.products.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(store.products) { product in
                        Button { Task { await store.buy(product) } } label: {
                            LabeledContent {
                                Text(product.displayPrice + period(product)).monospacedDigit()
                            } label: {
                                Text(product.displayName)
                                if product.id == store.activeProductID { Text("Current plan") }
                            }
                        }
                        .disabled(store.busy || product.id == store.activeProductID)
                    }
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
        .navigationTitle("orgstar Pro")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $managing)
        .task { await store.loadProducts() }
    }

    private var status: String {
        switch access.grant {
        case .grandfathered: "Pro is included: you downloaded orgstar before Pro. Thank you."
        case .purchase: store.activeProductID == ProStore.lifetime ? "You own orgstar Pro." : "Your orgstar Pro subscription is active."
        case .license, nil: "Pro adds power features and Apple integrations."
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
