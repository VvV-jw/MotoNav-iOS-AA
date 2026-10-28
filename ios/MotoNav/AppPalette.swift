import SwiftUI
import UIKit

/// Phone interface colors. Map layers, road signals and display packets keep
/// their own rendering palettes.
enum AppPalette {
    private static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
    static let background = rgb(0x0E0F10)
    static let surface = rgb(0x181A1C)
    static let raised = rgb(0x232629)
    static let border = rgb(0x35393C)
    static let text = rgb(0xF3F2EF)
    static let secondary = rgb(0xADB2B6)
    static let accent = rgb(0xA6B8C5)
    static let control = rgb(0x677781)
    static let success = rgb(0xA6B6AA)
    static let warning = rgb(0xBDAA89)
    static let error = rgb(0xC48F8C)
    static let action = rgb(0xE7E9E8)
    static let actionText = rgb(0x151719)

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
            .preferredColorScheme(.dark)
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
            .foregroundColor(enabled ? (configuration.role == .destructive ? AppPalette.error : AppPalette.accent) : AppPalette.secondary.opacity(0.6))
            .frame(minHeight: 44)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    func appScreen() -> some View { modifier(AppScreenTheme()) }
    func appListSurface() -> some View { modifier(AppListSurface()) }
}

