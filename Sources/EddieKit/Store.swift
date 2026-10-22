import Foundation
import Observation
import Security
import StoreKit

/// What the user may do. Editing never depends on it: projects open, edit and save in every case,
/// and only export waits for the trial or the purchase.
enum Access: Equatable {
    /// Bought, or a build signed on this Mac (`Store.isLocalBuild`).
    case unlocked
    case trial(daysLeft: Int)
    case trialEnded
    /// The 14 days haven't been started.
    case notStarted

    static let trialDays = 14

    var canExport: Bool {
        switch self {
        case .unlocked, .trial: true
        case .trialEnded, .notStarted: false
        }
    }

    /// The rules in one place, so the self test can check them without the App Store. The trial runs
    /// for 14 days from the moment it was started; the last partial day counts as a day left.
    static func compute(unlocked: Bool, trialStart: Date?, now: Date) -> Access {
        if unlocked { return .unlocked }
        guard let trialStart else { return .notStarted }
        let left = trialStart.addingTimeInterval(TimeInterval(trialDays) * 86_400).timeIntervalSince(now)
        guard left > 0 else { return .trialEnded }
        return .trial(daysLeft: min(Int((left / 86_400).rounded(.up)), trialDays))
    }
}

/// The 14-day trial and the one-time purchase, both non-consumables (StoreKit 2, checked on this Mac,
/// no server). The trial is a $0 purchase in the user's Apple Account, so a reinstall doesn't restart it,
/// and its purchase date starts the 14 days. Nothing here ever fails silently: a price that won't load,
/// a purchase that fails and a restore that can't reach the App Store all say so.
@MainActor @Observable
final class Store {
    nonisolated static let trialID = "com.iamjarl.edwell.trial"
    nonisolated static let unlockID = "com.iamjarl.edwell.unlock"

    /// A build signed on this Mac rather than by a team (`swift build`, `./build.sh`) has no App Store
    /// behind it, so it is unlocked. App Store, TestFlight and Xcode builds carry a team and use StoreKit.
    nonisolated static let isLocalBuild: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return true }
        return info[kSecCodeInfoTeamIdentifier as String] == nil
    }()

    private(set) var trialProduct: Product?
    private(set) var unlockProduct: Product?
    private(set) var unlocked = false
    private(set) var trialStart: Date?
    private(set) var isLoading = false
    /// A purchase or a restore is under way.
    private(set) var isBusy = false
    /// What went wrong or is pending, for the purchase sheet. Nil when there is nothing to say.
    private(set) var message: String?
    var showsPurchase = false

    @ObservationIgnored let localBuild: Bool
    /// The clock the trial is measured against; the StoreKit tests move it forward.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(localBuild: Bool = Store.isLocalBuild) {
        self.localBuild = localBuild
        guard !localBuild else { return }
        // Purchases can also finish outside the sheet: Ask to Buy, another Mac, a refund.
        updates = Task { [weak self] in
            for await _ in Transaction.updates { await self?.refresh() }
        }
        Task { await load() }
    }

    var access: Access {
        localBuild ? .unlocked : Access.compute(unlocked: unlocked, trialStart: trialStart, now: now())
    }

    func load() async {
        await refresh()
        await loadProducts()
    }

    /// Fetches both products. Safe to call again: a load that failed at launch (offline, or the products
    /// not yet approved) must not stay failed, and the sheet offers Try Again.
    @discardableResult
    func loadProducts() async -> Bool {
        guard !localBuild else { return false }
        // A load already under way (the one at launch) is waited for, not skipped.
        if let loading { await loading.value; return unlockProduct != nil }
        let task = Task { await fetchProducts() }
        loading = task
        isLoading = true
        await task.value
        loading = nil
        isLoading = false
        return unlockProduct != nil
    }

    @ObservationIgnored private var loading: Task<Void, Never>?

    private func fetchProducts() async {
        do {
            let products = try await Product.products(for: [Self.trialID, Self.unlockID])
            trialProduct = products.first { $0.id == Self.trialID }
            unlockProduct = products.first { $0.id == Self.unlockID }
        } catch {
            trialProduct = nil
            unlockProduct = nil
        }
        message = unlockProduct == nil
            ? String(localized: "The App Store can't be reached right now, so the price can't be shown. Check your connection and try again.")
            : nil
    }

    func startTrial() async { await purchase(Self.trialID) }

    func buy() async { await purchase(Self.unlockID) }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            message = String(localized: "The App Store can't be reached to restore your purchase. Check your connection and try again.")
            return
        }
        await refresh()
        if !unlocked {
            message = String(localized: "There's no purchase of Edwell to restore for this Apple Account.")
        }
    }

    private func purchase(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        // A product that failed to load at launch gets one more try before the sheet says so.
        if unlockProduct == nil || trialProduct == nil { await loadProducts() }
        guard let product = id == Self.trialID ? trialProduct : unlockProduct else {
            message = String(localized: "The App Store can't be reached right now. Check your connection and try again.")
            return
        }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh()
            case .success(.unverified):
                message = String(localized: "The App Store couldn't confirm the purchase. If you were charged, choose Restore Purchases.")
            case .pending:
                message = String(localized: "The purchase is waiting for approval. Edwell unlocks as soon as it's approved.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = String(localized: "The purchase didn't go through. Check your connection and try again.")
        }
    }

    /// Reads what this Apple Account owns. Works offline from the App Store's local record.
    func refresh() async {
        var owned = false
        var started: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case Self.unlockID: owned = true
            case Self.trialID: started = min(started ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate)
            default: break
            }
        }
        unlocked = owned
        trialStart = started
    }
}
