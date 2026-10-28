import SwiftUI

/// Navigation and the rest of the phone share the same day/night surfaces.
/// GTA keeps its yellow route accent; traffic-signal state colors are separate.
enum NavigationPalette {
    static let background = AppPalette.background
    static let surface = AppPalette.surface
    static let raised = AppPalette.raised
    static let text = AppPalette.text
    static let secondary = AppPalette.secondary
    static let border = AppPalette.border
    static var accent: Color {
        Settings.shared.theme == 2 ? AppPalette.adaptive(0x786700, 0xD6C74A) : AppPalette.accent
    }
    static let driveAccent = AppPalette.accent
    static let warning = AppPalette.warning
    static let error = AppPalette.error
}

struct NavigationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .foregroundColor(enabled ? NavigationPalette.accent : NavigationPalette.secondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(NavigationPalette.raised.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NavigationPalette.border, lineWidth: 1))
    }
}

private struct NavigationScreenTheme: ViewModifier {
    @ObservedObject private var settings = Settings.shared
    func body(content: Content) -> some View {
        content.foregroundColor(NavigationPalette.text)
            .tint(NavigationPalette.accent)
            .background(NavigationPalette.background.ignoresSafeArea())
            .preferredColorScheme(settings.paletteNight ? .dark : .light)
    }
}

extension View {
    func navigationScreen() -> some View { modifier(NavigationScreenTheme()) }
}
