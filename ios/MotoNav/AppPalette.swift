import SwiftUI
import UIKit

/// Phone surfaces follow the root's day/night trait. Dynamic UIColors allow
/// cached Color aliases, open sheets and UIKit controls to change in place.
/// No Settings dependency: the SDK-free preview host also compiles this file.
enum AppPalette {
    private static func uiColor(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func adaptive(_ day: UInt32, _ night: UInt32) -> Color {
        Color(UIColor { trait in
            uiColor(trait.userInterfaceStyle == .dark ? night : day)
        })
    }

    // Apple-inspired neutral grouped layers, with a restrained custom blue accent.
    static let background = adaptive(0xF2F2F7, 0x101012)
    static let surface = adaptive(0xFFFFFF, 0x1C1C1E)
    static let raised = adaptive(0xE9E9EF, 0x2C2C2E)
    static let border = adaptive(0xC7C7CC, 0x3A3A3C)
    static let text = adaptive(0x1C1C1E, 0xF2F2F7)
    static let secondary = adaptive(0x5E5E66, 0xAEAEB2)
    static let accent = adaptive(0x46688E, 0xA2BBDC)
    static let control = adaptive(0x6C809B, 0x7E94B0)
    static let success = adaptive(0x4F6C5C, 0x9EB6A6)
    static let warning = adaptive(0x7A623C, 0xC9B58E)
    static let error = adaptive(0x9C5053, 0xD1A1A4)
    static let action = adaptive(0x3F5E83, 0xB4C4DC)
    static let actionText = adaptive(0xFFFFFF, 0x151A22)

    static func configureSystemAppearance() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = UIColor(background)
        navigation.shadowColor = UIColor(border)
        navigation.titleTextAttributes = [.foregroundColor: UIColor(text)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(text)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().tintColor = UIColor(accent)
        UITableView.appearance().backgroundColor = UIColor(background)
        UITableView.appearance().separatorColor = UIColor(border)
        UITableViewCell.appearance().backgroundColor = UIColor(surface)
        UISwitch.appearance().onTintColor = UIColor(control)
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(raised)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(secondary)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(text)], for: .selected)
    }
}

private struct AppScreenTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundColor(AppPalette.text)
            .tint(AppPalette.accent)
            .background(AppPalette.background.ignoresSafeArea())
            .onAppear { AppPalette.configureSystemAppearance() }
    }
}

private struct AppListSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden).background(AppPalette.background)
        } else {
            content.background(AppPalette.background)
        }
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(enabled ? AppPalette.text : AppPalette.secondary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill((enabled ? AppPalette.raised : AppPalette.surface).opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppPalette.border, lineWidth: 1))
    }
}

struct AppListActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(enabled ? (configuration.role == .destructive ? AppPalette.error : AppPalette.accent) : AppPalette.secondary)
            .frame(minHeight: 44)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    func appScreen() -> some View { modifier(AppScreenTheme()) }
    func appListSurface() -> some View { modifier(AppListSurface()) }
}

