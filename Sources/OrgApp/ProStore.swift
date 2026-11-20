#if canImport(StoreKit)
import Foundation
import Observation
import StoreKit

/// orgstar+ from the App Store: a monthly or yearly subscription, or a lifetime purchase. It
/// keeps `ProAccess.shared` current; iOS installs from before Pro keep it without buying.
@MainActor @Observable
public final class ProStore {
    public static let shared = ProStore()

    public static let monthly = "sh.krz.orgstar.pro.monthly"
    public static let yearly = "sh.krz.orgstar.pro.yearly"
    public static let lifetime = "sh.krz.orgstar.pro.lifetime"
    public static let productIDs = [monthly, yearly, lifetime]

    /// Whether downloads from before Pro keep it free. Only on iOS; the Mac App Store app never
    /// grandfathers.
    public static let grandfathers: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()

    /// How much a yearly price saves against twelve monthly ones, in whole percent, or nil when
    /// it saves nothing.
    public nonisolated static func yearlySavings(yearly: Decimal, monthly: Decimal) -> Int? {
        guard monthly > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: yearly / (monthly * 12)).doubleValue
        let percent = Int((1 - ratio) * 100)
        return percent > 0 ? percent : nil
    }

    public private(set) var products: [Product] = []
    public private(set) var activeProductID: String?
    public private(set) var busy = false
    public private(set) var isLoading = false
    public var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    private init() {}

    /// Starts listening for transactions and checks what's owned. Call once at launch, and only
    /// from App Store builds: it sets the grant from StoreKit alone, replacing a license grant.
    public func start() {
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

    public func loadProducts() async {
        guard products.count < Self.productIDs.count, !isLoading else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = Self.productIDs.compactMap { id in fetched.first { $0.id == id } }
            if products.count < Self.productIDs.count {
                message = String(localized: "Some plans aren't available from the App Store right now.")
            }
        } catch {
            message = String(localized: "The App Store can't be reached right now.")
        }
    }

    /// Sets Pro from the current entitlements, or from the original download predating Pro.
    public func refresh() async {
        var active: String?
        var expires: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if active == nil || transaction.productID == Self.lifetime { active = transaction.productID }
            if let date = transaction.expirationDate { expires = max(expires ?? date, date) }
        }
        activeProductID = active
        #if os(macOS)
        refresh(at: active == Self.lifetime ? nil : expires)
        #endif
        if active != nil {
            ProAccess.shared.set(.purchase)
        } else if await Self.predatesPro() {
            ProAccess.shared.set(.grandfathered)
        } else if ProAccess.shared.grant != .grandfathered {
            // A cached grandfathered grant survives the App Store being unreachable.
            ProAccess.shared.set(nil)
        }
    }

    #if os(macOS)
    /// Checks again when a subscription runs out, since StoreKit sends no update for a lapse and
    /// the Mac app can stay open for weeks.
    private func refresh(at date: Date?) {
        expiry?.cancel()
        expiry = nil
        guard let date, date > .now else { return }
        expiry = Task {
            try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow + 1))
            guard !Task.isCancelled else { return }
            // A new task, so cancelling this one can't cut the entitlement check short.
            Task { await ProStore.shared.refresh() }
        }
    }
    #endif

    /// Whether this Apple Account first downloaded orgstar before Pro. Only the production App
    /// Store reports real original versions; sandbox and Xcode always say "1.0".
    private static func predatesPro() async -> Bool {
        guard grandfathers, case .verified(let app) = try? await AppTransaction.shared, app.environment == .production else { return false }
        return Grandfathering.predatesPro(originalBuild: app.originalAppVersion)
    }

    public func buy(_ product: Product) async {
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

    public func restore() async {
        busy = true
        defer { busy = false }
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            if !ProAccess.shared.isUnlocked { message = "No orgstar+ purchase was found for this Apple Account." }
        } catch {
            message = "Restore didn't finish. \(error.localizedDescription)"
        }
    }
}
#endif
