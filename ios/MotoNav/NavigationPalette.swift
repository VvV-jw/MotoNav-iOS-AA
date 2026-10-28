import SwiftUI

/// Navigation controls follow the map's actual day/night choice. Home and settings
/// retain their graphite surfaces; red/yellow/green signal meanings are unchanged.
enum NavigationPalette {
    private static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
    static var background: Color { rgb(Settings.shared.paletteNight ? 0x171A1D : 0xEEF0ED) }
    static var surface: Color { rgb(Settings.shared.paletteNight ? 0x20262B : 0xFAFBF8) }
    static var raised: Color { rgb(Settings.shared.paletteNight ? 0x2D353B : 0xE8EDEB) }
    static var text: Color { rgb(Settings.shared.paletteNight ? 0xF1F3EE : 0x20292E) }
    static var secondary: Color { rgb(Settings.shared.paletteNight ? 0xB4BEC3 : 0x57666D) }
    static var border: Color { rgb(Settings.shared.paletteNight ? 0x49545B : 0xC2CFCE) }
    static var accent: Color {
        rgb(Settings.shared.theme == 2 ? (Settings.shared.paletteNight ? 0xD6C74A : 0x786700) :
            (Settings.shared.paletteNight ? 0x9ABFD8 : 0x386F9B))
    }
    static var driveAccent: Color { rgb(Settings.shared.paletteNight ? 0x9ABFD8 : 0x386F9B) }
    static var warning: Color { rgb(Settings.shared.paletteNight ? 0xD1B17C : 0x80612F) }
    static var error: Color { rgb(Settings.shared.paletteNight ? 0xD8A09A : 0xA1423B) }
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

extension View {
    func navigationScreen() -> some View {
        foregroundColor(NavigationPalette.text)
            .tint(NavigationPalette.accent)
            .background(NavigationPalette.background.ignoresSafeArea())
            .preferredColorScheme(Settings.shared.paletteNight ? .dark : .light)
    }
}
