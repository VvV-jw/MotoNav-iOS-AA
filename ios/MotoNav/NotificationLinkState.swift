import Foundation

/// ANCS is owned by iOS and the accessory. These replies report only the
/// accessory's subscription state, never permission denial or message content.
struct NotificationLinkState: Equatable {
    private(set) var supported = false
    private(set) var ready = false

    mutating func receive(_ packet: String) -> Bool {
        switch packet {
        case "CAP,ANCS,1":
            supported = true
        case "ANC,0":
            supported = true
            ready = false
        case "ANC,1":
            supported = true
            ready = true
        default:
            return false
        }
        return true
    }

    mutating func reset() { self = Self() }

    func status(connected: Bool) -> String {
        guard connected else { return "连接圆屏后查看通知状态" }
        guard supported else { return "正在确认圆屏通知支持" }
        return ready ? "iPhone 通知已连接" : "等待 iPhone 通知连接"
    }
}
