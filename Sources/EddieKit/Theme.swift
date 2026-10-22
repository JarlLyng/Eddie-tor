import IAMJARLDesignTokens
import SwiftUI

/// Every colour, size and radius in Eddie's interface comes from the IAMJARL design system.
/// Colours in the video itself (title colours, the project background) are the user's content, not UI.
typealias Tokens = DesignTokens

extension Tokens {
    /// A clip on the timeline: a neutral tint of the text colour, so it reads on the lane in both modes.
    /// The kind of clip shows in its content (frames, waveform, text) and icon rather than in a colour of its own.
    static let clipFill = Palette.Text.primary.opacity(0.14)
}

/// The design system's primary button: `primary` with `onPrimary` text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ijFont(.base, weight: .semibold)
            .foregroundStyle(Tokens.Palette.onPrimary)
            .padding(.vertical, Tokens.Spacing.sm)
            .padding(.horizontal, Tokens.Spacing.xl)
            .background(configuration.isPressed ? Tokens.Palette.primaryPressed : Tokens.Palette.primary,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .opacity(isEnabled ? 1 : Tokens.Opacity.disabled)
    }
}

/// The design system's secondary button: a card with a subtle border.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ijFont(.base)
            .foregroundStyle(Tokens.Palette.Text.primary)
            .padding(.vertical, Tokens.Spacing.sm)
            .padding(.horizontal, Tokens.Spacing.xl)
            .background(configuration.isPressed ? Tokens.Palette.Background.muted : Tokens.Palette.Background.card,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Palette.Border.subtle))
            .opacity(isEnabled ? 1 : Tokens.Opacity.disabled)
    }
}
