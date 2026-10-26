import Foundation

/// UI readiness policy, independent of CoreLocation so stale/invalid fixes can be replayed on a computer.
enum LocationReadiness {
    enum Permission { case unknown, denied, restricted, allowed }
    enum Level: Equatable { case ready, waiting, attention }
    struct Result {
        let level: Level
        let title: String
        let detail: String
        var usable: Bool { level == .ready }
    }

    static func evaluate(permission: Permission, fixAge: TimeInterval?, accuracy: Double?,
                         validCoordinate: Bool, fullAccuracy: Bool) -> Result {
        switch permission {
        case .denied, .restricted:
            return Result(level: .attention, title: "定位未授权", detail: "在系统设置中允许定位后，再准备路线")
        case .unknown:
            return Result(level: .waiting, title: "等待定位授权", detail: "允许定位后才能从当前位置规划")
        case .allowed: break
        }
        guard let age = fixAge, let accuracy = accuracy, age.isFinite, accuracy.isFinite,
              validCoordinate, accuracy >= 0, age >= -5 else {
            return Result(level: .waiting, title: "等待有效定位", detail: "保持 App 前台，取得当前位置后继续")
        }
        guard age <= 20 else {
            return Result(level: .attention, title: "定位尚未更新", detail: "当前定位已超过 20 秒，等待新位置")
        }
        guard fullAccuracy else {
            return Result(level: .attention, title: "定位为大致位置", detail: "在系统设置中开启“精确位置”，改善路线起点和地图跟随")
        }
        guard accuracy <= 100 else {
            return Result(level: .attention, title: "定位精度不足", detail: "当前误差约 \(Int(min(accuracy, 99_999))) 米，等待定位改善")
        }
        return Result(level: .ready, title: "当前位置已更新", detail: "定位误差约 \(Int(accuracy.rounded())) 米")
    }
}
