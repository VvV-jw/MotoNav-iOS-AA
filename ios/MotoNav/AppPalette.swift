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

    // Porcelain and cool graphite, with a restrained mineral-blue accent.
    static let background = adaptive(0xF1F2F0, 0x121619)
    static let surface = adaptive(0xFAFAF7, 0x1B2226)
    static let raised = adaptive(0xE7ECEB, 0x293236)
    static let border = adaptive(0xBAC5C7, 0x445258)
    static let text = adaptive(0x20262A, 0xE7EBE8)
    static let secondary = adaptive(0x56646A, 0xAFBABD)
    static let accent = adaptive(0x42616E, 0xA8BDC4)
    static let control = adaptive(0x56717A, 0x6E8993)
    static let success = adaptive(0x4A6656, 0xA5B9AA)
    static let warning = adaptive(0x7A623C, 0xC8B28A)
    static let error = adaptive(0x984F4A, 0xD2A4A0)
    static let action = adaptive(0x425B65, 0xB4C6CA)
    static let actionText = adaptive(0xFAFBF8, 0x172226)

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

