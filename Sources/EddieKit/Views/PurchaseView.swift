import IAMJARLDesignTokens
import SwiftUI

/// The trial and the purchase, said plainly: what you get, how long the trial runs, what stops when it
/// ends (export, never editing) and the price from the App Store. Before the trial starts, App Review
/// (guideline 3.1.1) wants all three on this screen, so the trial can't be started without the price.
struct PurchaseView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            Text(title).ijFont(.xl, weight: .semibold)
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                Text(text).ijFont(.base).fixedSize(horizontal: false, vertical: true)
            }

            if let message = store.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .ijFont(.sm)
                    .foregroundStyle(Tokens.Palette.State.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The way in on its own row, wrapping to a column where a language's labels are long.
            if store.access != .unlocked {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Spacing.sm) { Spacer(minLength: 0); actions }
                    VStack(alignment: .trailing, spacing: Tokens.Spacing.sm) { actions }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .disabled(store.isBusy)
            }

            HStack(spacing: Tokens.Spacing.sm) {
                if store.access != .unlocked {
                    Button("Restore Purchases") { Task { await store.restore() } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Tokens.Palette.Text.secondary)
                        .ijFont(.sm)
                        .fixedSize()
                }
                if store.isBusy || store.isLoading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button(store.access == .unlocked ? "Close" : "Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
            }
            .disabled(store.isBusy)
        }
        .padding(Tokens.Spacing.xxl)
        .frame(width: 460)
        .task { if store.unlockProduct == nil { await store.loadProducts() } }
    }

    @ViewBuilder private var actions: some View {
        if store.access != .unlocked {
            if let unlock = store.unlockProduct {
                if store.access == .notStarted, store.trialProduct != nil {
                    Button("Buy for \(unlock.displayPrice)") { Task { await store.buy() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .fixedSize()
                    Button("Start 14-day Trial") { Task { await store.startTrial() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PrimaryButtonStyle())
                        .fixedSize()
                } else {
                    Button("Buy for \(unlock.displayPrice)") { Task { await store.buy() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PrimaryButtonStyle())
                        .fixedSize()
                }
            } else {
                Button("Try Again") { Task { await store.loadProducts() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
                    .disabled(store.isLoading)
            }
        }
    }

    private var title: String { PurchaseCopy.title(store.access) }

    private var paragraphs: [String] { PurchaseCopy.paragraphs(store.access, price: store.unlockProduct?.displayPrice) }
}

/// The way to the sheet from the toolbar, for someone who chose Not Now or is partway through the trial.
/// It counts the days down, and once they're over it asks in the accent.
struct PurchaseButton: View {
    @Environment(Store.self) private var store

    var body: some View {
        // The days left go down while the window stays open.
        TimelineView(.everyMinute) { _ in
            if let label = PurchaseCopy.toolbar(store.access) {
                let button = Button(label.title) { store.showsPurchase = true }
                    .accessibilityLabel(label.voiceOver)
                if store.access == .trialEnded {
                    button.buttonStyle(PrimaryButtonStyle(compact: true))
                } else if #available(macOS 26, *) {
                    // Plain glass, like the toolbar's own; the window's tint would fill it with the accent.
                    button.ijFont(.sm).buttonStyle(.glass).tint(nil)
                } else {
                    button.ijFont(.sm)
                }
            }
        }
    }
}

/// `PurchaseButton` just left of Export. On macOS 26 it draws its own glass, so the toolbar doesn't
/// put the accent button and Export together in one.
struct PurchaseToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { PurchaseButton() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { PurchaseButton() }
        }
    }
}

/// The sheet's words, kept apart from the view so the self test can read them. Before the trial
/// starts they must name its length, what stops when it ends, and the price (guideline 3.1.1).
enum PurchaseCopy {
    static func title(_ access: Access) -> String {
        switch access {
        case .notStarted: String(localized: "Try Edwell for 14 days")
        case .trial(let days): String(localized: "\(days) days left of your trial")
        case .trialEnded: String(localized: "Your 14 days are over")
        case .unlocked: String(localized: "Edwell is yours")
        }
    }

    static func paragraphs(_ access: Access, price: String?) -> [String] {
        let charge = price.map { String(localized: "That's \($0) once, with no subscription. Pay once and it's yours.") }
        switch access {
        case .notStarted:
            return [
                String(localized: "Everything works for 14 days, export included."),
                price.map { String(localized: "After that your projects still open and edit as before, and exporting needs a one-time purchase of \($0), with no subscription.") }
                    ?? String(localized: "After that your projects still open and edit as before, and exporting needs a one-time purchase, with no subscription."),
            ]
        case .trial:
            return [
                String(localized: "Everything works until then, export included. After that your projects still open and edit as before, and exporting needs the one-time purchase."),
                charge,
            ].compactMap { $0 }
        case .trialEnded:
            return [
                String(localized: "Your projects still open and edit as before. To export, buy Edwell once."),
                charge,
                String(localized: "I make Edwell on my own, and buying it is what keeps it going."),
            ].compactMap { $0 }
        case .unlocked:
            return [String(localized: "Thank you for buying it. Everything works, on every Mac signed in to your Apple Account.")]
        }
    }

    /// The toolbar's button to the sheet, as it reads and as VoiceOver says it; none once Edwell is bought.
    /// After the trial nothing says free.
    static func toolbar(_ access: Access) -> (title: String, voiceOver: String)? {
        switch access {
        case .notStarted:
            (String(localized: "Try Edwell free"), String(localized: "Try Edwell free for 14 days"))
        case .trial(let days):
            (String(localized: "\(days) days left · Buy"), String(localized: "Buy Edwell, \(days) days left of your trial"))
        case .trialEnded:
            (String(localized: "Buy Edwell"), String(localized: "Buy Edwell, your trial is over"))
        case .unlocked:
            nil
        }
    }
}
