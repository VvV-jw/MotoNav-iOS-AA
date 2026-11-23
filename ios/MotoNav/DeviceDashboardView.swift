import SwiftUI

struct DeviceDashboardView: View {
    @ObservedObject var ble: BleLink
    @ObservedObject private var settings = Settings.shared
    let openDisplay: () -> Void
    let openSettings: () -> Void
    let openMap: () -> Void
    @State private var sheet: DeviceSheet?

    private enum DeviceSheet: String, Identifiable {
        case connection, notifications
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("圆屏").font(.largeTitle.weight(.bold))
                    Spacer()
                    Button { sheet = .connection } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title3).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("我的圆屏")
                    .accessibilityIdentifier("device.manage")
                }
                DeviceSummaryCard(state: ble.device, connected: ble.isReady,
                    style: Settings.themeName(settings.theme),
                    manage: manageDevice, openDisplay: openDisplay, openSettings: openSettings)
                DeviceConnectionSection(state: ble.device, detail: ble.status,
                    manage: manageDevice, disconnect: ble.disconnect)
                DeviceGroup {
                    CurrentMapStatusView(title: "当前路网", refreshIdentifier: "map.current.refresh")
                    Divider()
                    Button(action: openMap) {
                        DeviceSettingsRow(symbol: "map", title: "地图与导航", value: nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("device.navigation.open")
                }
                DeviceGroup {
                    Button { sheet = .notifications } label: {
                        DeviceSettingsRow(symbol: "bell", title: "iPhone 通知",
                            value: ble.isReady && ble.notificationLink.ready ? "已连接" : "检查连接")
                    }.buttonStyle(.plain).accessibilityIdentifier("device.notifications.open")
                    Divider()
                    Button(action: openSettings) {
                        DeviceSettingsRow(symbol: "music.note", title: "音乐与实体按键", value: nil)
                    }.buttonStyle(.plain).accessibilityIdentifier("device.music.open")
                }
                Text("MotoNav · \(APP_VERSION)")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.bottom, 8)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $sheet) { selected in
            switch selected {
            case .connection: MyRoundDeviceSheet(ble: ble)
            case .notifications:
                DeviceDetailSheet(title: "iPhone 通知") {
                    NotificationSettingsView(connected: ble.isReady, state: ble.notificationLink,
                        test: ble.testNotification, refresh: ble.retryNotificationCapability)
                }
            }
        }
    }

    private func manageDevice() {
        if !ble.isReady && !ble.device.connection.busy { ble.connect() }
        sheet = .connection
    }
}

private struct DeviceSummaryCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let state: RoundDeviceState
    let connected: Bool
    let style: String
    let manage: () -> Void
    let openDisplay: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    DeviceProductImage().frame(maxHeight: 180).frame(maxWidth: .infinity)
                }.padding(20)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    summary.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    DeviceProductImage().frame(width: 138, height: 180)
                }.padding(20)
            }
            Divider().padding(.horizontal, 20)
            HStack(spacing: 0) {
                Button(action: openDisplay) {
                    Label("圆屏显示", systemImage: "sun.max")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
                }.accessibilityIdentifier("device.display.open")
                Divider().frame(height: 26)
                Button(action: openSettings) {
                    Label("圆屏设置", systemImage: "gearshape")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
                }.accessibilityIdentifier("device.settings.open")
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("导航屏").font(.caption).foregroundStyle(.secondary)
            Text(state.name).font(.title2.weight(.bold)).lineLimit(2)
                .accessibilityIdentifier("device.name")
            DeviceConnectionLabel(connection: state.connection)
            VStack(alignment: .leading, spacing: 3) {
                Text("设备电量").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if state.charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    Text(state.batteryText).font(.headline).monospacedDigit()
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("device.battery")
            }.padding(.top, 3)
            Button(action: manage) {
                Label(connected ? "管理" : state.connection.busy ? "连接中" : "连接",
                    systemImage: connected ? "link" : "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("device.connect")
            Text(style).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct DeviceProductImage: View {
    var body: some View {
        Image("RoundDevice")
            .resizable().scaledToFit()
            .accessibilityLabel("MotoNav 圆屏导航设备")
    }
}

private struct DeviceConnectionLabel: View {
    let connection: RoundDeviceState.Connection
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connection == .ready ? Color.green : connection.busy ? Color.orange : Color.secondary)
                .frame(width: 7, height: 7).accessibilityHidden(true)
            Text(connection.title).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("device.connection.status")
        }.accessibilityElement(children: .combine)
    }
}

private struct DeviceConnectionSection: View {
    let state: RoundDeviceState
    let detail: String
    let manage: () -> Void
    let disconnect: () -> Void
    var body: some View {
        DeviceGroup {
            Text("连接管理").font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: manage) {
                    Label("我的圆屏", systemImage: "antenna.radiowaves.left.and.right")
                }.accessibilityIdentifier("device.connection.open")
                Spacer()
                if state.connection == .ready {
                    Button("断开", action: disconnect)
                        .accessibilityIdentifier("device.disconnect")
                }
            }.font(.subheadline).buttonStyle(.plain).foregroundStyle(Color.accentColor).frame(minHeight: 40)
        }
    }
}

struct MyRoundDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ble: BleLink
    @ObservedObject private var location = LocationService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack {
                    Text("我的圆屏").font(.headline)
                    HStack {
                        Spacer()
                        Button("完成") { dismiss() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .accessibilityIdentifier("device.sheet.done")
                    }
                }.frame(minHeight: 44)
                VStack(spacing: 14) {
                    DeviceProductImage().frame(height: 188)
                    Text(ble.device.name).font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(ble.isReady ? "圆屏已连接，导航会自动同步。" : "请将已开机的圆屏放在手机附近。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                DeviceGroup {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right").frame(width: 24)
                        Text("连接状态")
                        Spacer(minLength: 8)
                        Text(ble.device.connection.title).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("device.sheet.connection")
                    }.font(.subheadline).frame(minHeight: 32)
                    Divider()
                    Button(action: connectionAction) {
                        Text(ble.isReady ? "断开连接" : ble.device.connection.busy ? "停止搜索" : "搜索圆屏")
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("device.sheet.search")
                }
                Text("圆屏保持开机并靠近 iPhone。连接成功后，当前导航会自动同步。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 10) {
                    Text("定位").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let result = location.readiness(at: context.date)
                        DeviceGroup {
                            Button { location.start() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "location").frame(width: 24)
                                    Text("搜索位置")
                                    Spacer(minLength: 8)
                                    Text(result.usable ? "已获取" : result.title)
                                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                }.font(.subheadline).frame(minHeight: 32)
                            }.buttonStyle(.plain).accessibilityIdentifier("device.sheet.location")
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .appScreen().deviceSheetStyle()
    }

    private func connectionAction() {
        if ble.isReady || ble.device.connection.busy { ble.disconnect() }
        else { ble.connect() }
    }
}

struct DeviceDetailSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 40, height: 40)
                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .accessibilityLabel("关闭").accessibilityIdentifier("device.detail.close")
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }.appScreen().deviceSheetStyle()
    }
}

struct DeviceGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct DeviceSettingsRow: View {
    let symbol: String
    let title: String
    let value: String?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 24)
            Text(title)
            Spacer(minLength: 8)
            if let value = value { Text(value).font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.font(.subheadline).frame(minHeight: 34)
            .contentShape(Rectangle())
    }
}

private struct DeviceSheetStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.large]).presentationDragIndicator(.visible)
        } else { content }
    }
}

private extension View {
    func deviceSheetStyle() -> some View { modifier(DeviceSheetStyle()) }
}
