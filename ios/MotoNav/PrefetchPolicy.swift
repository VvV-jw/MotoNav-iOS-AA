import Foundation

/// Applies exclusively to background route preparation. Current-map work always bypasses it.
enum PrefetchPolicy {
    enum Decision: String { case allow = "ALLOW", waitNetwork = "WAIT_NETWORK", waitCharging = "WAIT_CHARGING", both = "WAIT_NETWORK_AND_CHARGING" }
    static func decide(foreground: Bool, wifiOnly: Bool, chargingOnly: Bool,
                       unmeteredWifi: Bool, charging: Bool) -> Decision {
        if foreground { return .allow }
        let network = wifiOnly && !unmeteredWifi, power = chargingOnly && !charging
        return network ? (power ? .both : .waitNetwork) : (power ? .waitCharging : .allow)
    }
    static func detail(_ decision: Decision) -> String {
        switch decision {
        case .allow: return "沿线预下载可继续"
        case .waitNetwork: return "等待不计费 Wi-Fi 后自动继续沿线预下载"
        case .waitCharging: return "接入电源后自动继续沿线预下载"
        case .both: return "等待不计费 Wi-Fi 和充电后自动继续沿线预下载"
        }
    }
}
