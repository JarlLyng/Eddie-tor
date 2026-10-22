import AppKit
import StoreKit
import SwiftUI
import StoreKitTest
import IAMJARLDesignTokens
import XCTest
@testable import EddieKit

/// The trial and the purchase against Xcode's local StoreKit (Edwell.storekit), the cases the self test
/// can't reach: starting the trial, its end, buying, a relaunch, a refund, Ask to Buy, and an App Store
/// that can't be reached, which must never fail silently.
///   xcodebuild test -project App/Edwell.xcodeproj -scheme Edwell -destination 'platform=macOS'
@MainActor
final class StoreTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: StoreTests.self).url(forResource: "Edwell", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        // Never buy anything from the real (sandbox) App Store: that puts purchase dialogs on the screen.
        // The products must come from Edwell.storekit, which loading them shows without any dialog.
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let local = (config?["products"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { result, product in
            let description = (product["localizations"] as? [[String: Any]])?.first?["description"] as? String
            result[product["productID"] as? String ?? ""] = description
        }
        let products = try await Product.products(for: [Store.trialID, Store.unlockID])
        guard products.count == 2, products.allSatisfy({ local[$0.id] == $0.description }) else {
            throw XCTSkip("StoreKit isn't serving Edwell.storekit here, so nothing is bought.")
        }
    }

    override func tearDown() async throws {
        session.clearTransactions()
    }

    private func freshStore() async -> Store {
        let store = Store(localBuild: false)
        await store.load()
        return store
    }

    func testTrialThenPurchase() async throws {
        let store = await freshStore()
        XCTAssertEqual(store.unlockProduct?.id, Store.unlockID)
        XCTAssertEqual(store.trialProduct?.id, Store.trialID)
        // The price comes from StoreKit. Its test environment reads Edwell.storekit's price with this Mac's
        // number format and can drop the decimals, so the exact amount is the self test's to check.
        XCTAssertGreaterThan(store.unlockProduct?.price ?? 0, 0)
        XCTAssertEqual(store.trialProduct?.price, 0)
        XCTAssertEqual(store.access, .notStarted)
        XCTAssertFalse(store.access.canExport)

        await store.startTrial()
        XCTAssertEqual(store.access, .trial(daysLeft: 14))
        XCTAssertTrue(store.access.canExport)

        // A relaunch reads the trial back from the App Store's record and doesn't restart it.
        let relaunched = await freshStore()
        XCTAssertEqual(relaunched.access, .trial(daysLeft: 14))

        relaunched.now = { Date().addingTimeInterval(15 * 86_400) }
        XCTAssertEqual(relaunched.access, .trialEnded)
        XCTAssertFalse(relaunched.access.canExport)

        await relaunched.buy()
        XCTAssertEqual(relaunched.access, .unlocked)
        XCTAssertNil(relaunched.message)
    }

    func testBuyWithoutTrial() async throws {
        let store = await freshStore()
        await store.buy()
        XCTAssertEqual(store.access, .unlocked)
        let relaunched = await freshStore()
        XCTAssertEqual(relaunched.access, .unlocked)
    }

    func testRefundLocksExportAgain() async throws {
        let store = await freshStore()
        await store.buy()
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == Store.unlockID })
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        // The refund arrives through Transaction.updates.
        for _ in 0..<50 where store.access != .notStarted {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.access, .notStarted)
    }

    func testOfflineSaysSoAndRecovers() async throws {
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let store = await freshStore()
        XCTAssertNil(store.unlockProduct)
        XCTAssertNotNil(store.message, "an App Store that can't be reached must say so")

        // Buying while offline tries again and still says so, instead of doing nothing.
        await store.buy()
        XCTAssertNotNil(store.message)
        XCTAssertFalse(store.access.canExport)

        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        let loaded = await store.loadProducts()
        XCTAssertTrue(loaded)
        XCTAssertNil(store.message)
    }

    func testFailedPurchaseSaysSo() async throws {
        let store = await freshStore()
        try await session.setSimulatedError(.generic(.networkError(URLError(.networkConnectionLost))), forAPI: .purchase)
        await store.buy()
        XCTAssertNotNil(store.message)
        XCTAssertEqual(store.access, .notStarted)
    }

    /// Draws the purchase sheet in each state to `purchase-sheets/` in the app's temporary folder, for
    /// looking at: a local build is always unlocked, so this is where the other states can be seen.
    func testDrawSheets() async throws {
        let store = await freshStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("purchase-sheets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try draw(store, "1-not-started", in: folder)
        await store.startTrial()
        try draw(store, "2-trial", in: folder)
        store.now = { Date().addingTimeInterval(15 * 86_400) }
        try draw(store, "3-ended", in: folder)
        await store.buy()
        try draw(store, "4-bought", in: folder)
        print("purchase sheets: \(folder.path)")
    }

    private func draw(_ store: Store, _ name: String, in folder: URL) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // The sheet's own background stands in for the window's, and the window carries the
            // appearance, so colours resolve as they do in the app.
            let view = NSHostingView(rootView: PurchaseView().environment(store).background(Tokens.Palette.Background.app))
            view.frame = CGRect(origin: .zero, size: view.fittingSize)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    func testAskToBuyWaitsThenUnlocks() async throws {
        session.askToBuyEnabled = true
        let store = await freshStore()
        await store.buy()
        XCTAssertNotNil(store.message, "a pending purchase must say it's waiting")
        XCTAssertFalse(store.access.canExport)

        let pending = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == Store.unlockID })
        try session.approveAskToBuyTransaction(identifier: UInt(pending.identifier))
        for _ in 0..<50 where store.access != .unlocked {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.access, .unlocked, "an approved purchase arrives through Transaction.updates")
    }
}
