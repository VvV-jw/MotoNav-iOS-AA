import SwiftUI

struct NotificationSettingsView: View {
    let connected: Bool
    let state: NotificationLinkState
    let test: () -> Void
    let refresh: () -> Void

    var body: some View {
        CardView {
            Label("iPhone 通知", systemImage: "bell.badge")
                .font(.body.weight(.bold)).foregroundStyle(AppPalette.text)
            Label(state.status(connected: connected),
                  systemImage: connected && state.ready ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(connected && state.ready ? AppPalette.accent : AppPalette.secondary)
                .accessibilityIdentifier("notifications.connection.status")
            if connected && state.supported && !state.ready {
                Text("在 iPhone 设置 → 蓝牙 → MotoNav 中开启“共享系统通知”（如有此项），并允许配对时的通知请求。")
                    .font(.caption).foregroundStyle(AppPalette.secondary)
            }
            HStack {
                Button(action: refresh) {
                    Label("检查连接", systemImage: "arrow.clockwise")
                }
                .disabled(!connected)
                .accessibilityIdentifier("notifications.connection.refresh")
                Spacer()
                Button(action: test) {
                    Label("圆屏测试通知", systemImage: "bell")
                }
                .disabled(!connected || !state.supported)
                .accessibilityIdentifier("notifications.preview.test")
            }
            .tint(AppPalette.accent)
            Text("通知由 iPhone 直接通过蓝牙交给圆屏。圆屏测试显示示例消息；真实消息的正文遵循 iPhone 的通知与预览设置。")
                .font(.caption).foregroundStyle(AppPalette.secondary)
        }
    }
}
