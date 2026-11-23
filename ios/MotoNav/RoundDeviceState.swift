import Foundation

/// Accessory identity and power are reported by the round screen, never inferred
/// from the phone's name or battery. Reconnection clears the old power sample.
struct RoundDeviceState: Equatable {
    enum Connection: Equatable {
        case idle, searching, connecting, ready, retrying, bluetoothOff, unauthorized, unavailable

        var title: String {
            switch self {
            case .idle: return "未连接"
            case .searching: return "正在寻找圆屏"
            case .connecting: return "正在连接圆屏"
            case .ready: return "已连接"
            case .retrying: return "等待自动重连"
            case .bluetoothOff: return "蓝牙未开启"
            case .unauthorized: return "蓝牙未授权"
            case .unavailable: return "蓝牙暂不可用"
            }
        }

        var busy: Bool { self == .searching || self == .connecting || self == .retrying }
    }

    var name: String
    private(set) var connection: Connection = .idle
    private(set) var batteryPercent: Int?
    private(set) var charging = false
    private(set) var usbConnected = false

    init(name: String? = nil) {
        self.name = Self.cleanName(name) ?? "我的圆屏"
    }

    mutating func identify(_ name: String?) {
        if let name = Self.cleanName(name) { self.name = name }
    }

    mutating func transition(to value: Connection) {
        if value != .ready {
            batteryPercent = nil
            charging = false
            usbConnected = false
        }
        connection = value
    }

    @discardableResult mutating func receivePower(_ packet: String) -> Bool {
        let fields = packet.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "V",
              let percent = Int(fields[1]), (-1...100).contains(percent),
              ["0", "1"].contains(String(fields[2])), ["0", "1"].contains(String(fields[3])),
              let millivolts = Int(fields[4]), (0...6000).contains(millivolts) else { return false }
        guard connection == .ready else { return true }
        batteryPercent = percent < 0 ? nil : percent
        charging = fields[2] == "1"
        usbConnected = fields[3] == "1"
        return true
    }

    var batteryText: String {
        if let percent = batteryPercent { return "\(percent)%" }
        return usbConnected ? "USB 供电" : "—"
    }

    private static func cleanName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return name
    }
}
