import Foundation

/// The visible map's preparation and delivery are independent: a previous confirmed
/// block can remain useful while its replacement is being built or retried.
struct MapReadinessSnapshot: Equatable {
    enum Phase: String { case idle, disabled, notRequired, preparing, waitingForeground, waitingConnection, transferring, confirmed, stale, retrying }
    enum Severity: String { case neutral, progress, good, attention }
    enum Coverage: String { case unknown, unconfirmed, covered, uncovered }
    let phase: Phase
    let title: String
    let detail: String
    let severity: Severity
    let coverage: Coverage
    let hasPacket: Bool
    let confirmedAt: Date?
    let retryAt: Date?

    static let idle = MapReadinessSnapshot(phase: .idle, title: "导航时自动准备地图", detail: "选择路线后可提前准备沿线地图", severity: .neutral, coverage: .unconfirmed, hasPacket: false, confirmedAt: nil, retryAt: nil)
}

struct MapReadinessState {
    struct Packet: Equatable { let type: Int, id: Int }
    enum Preparation: Equatable {
        case idle, preparing, waitingForeground
        case failed(message: String, retryAt: Date)
    }
    enum Delivery: Equatable { case none, prepared, waitingConnection, transmitting, confirmed }
    private(set) var preparation = Preparation.idle
    private(set) var delivery = Delivery.none
    private(set) var packet: Packet?
    private(set) var confirmedAt: Date?
    private var awaitingAck: Packet?

    mutating func beginPreparation() { preparation = .preparing }
    mutating func finishPreparation() { preparation = .idle }
    mutating func waitForForeground() { preparation = .waitingForeground }
    mutating func failPreparation(_ message: String, retryAt: Date) { preparation = .failed(message: message, retryAt: retryAt) }
    mutating func accept(_ value: Packet) {
        packet = value; delivery = .prepared; awaitingAck = nil
        // Keep the old confirmation time: it belongs to the retained screen map.
    }
    @discardableResult mutating func beginSending(_ value: Packet, connected: Bool) -> Bool {
        guard packet == value else { return false }
        awaitingAck = connected ? value : nil
        delivery = connected ? .transmitting : .waitingConnection
        return connected
    }
    @discardableResult mutating func acknowledge(_ value: Packet, at date: Date) -> Bool {
        guard packet == value, awaitingAck == value else { return false }
        delivery = .confirmed; awaitingAck = nil; confirmedAt = date
        // An ACK confirms delivery only; it must not clear a later fetch failure.
        return true
    }
    mutating func disconnect() {
        awaitingAck = nil; confirmedAt = nil
        delivery = packet == nil ? .none : .waitingConnection
    }
    mutating func cancelPreparation() { preparation = .idle }
    mutating func cancelTransfer() {
        awaitingAck = nil
        if delivery != .confirmed { delivery = packet == nil ? .none : .prepared }
    }
    mutating func reset() { self = MapReadinessState() }

    func snapshot(enabled: Bool, usesBasemap: Bool, connected: Bool,
                  coverage: MapReadinessSnapshot.Coverage) -> MapReadinessSnapshot {
        let hasPacket = packet != nil
        let retained = coverage == .covered ? "圆屏已有地图仍覆盖当前位置" :
            (coverage == .uncovered ? "圆屏旧地图已不能覆盖当前位置" : "尚未确认圆屏地图覆盖当前位置")
        func make(_ phase: MapReadinessSnapshot.Phase, _ title: String, _ detail: String,
                  _ severity: MapReadinessSnapshot.Severity, retryAt: Date? = nil) -> MapReadinessSnapshot {
            MapReadinessSnapshot(phase: phase, title: title, detail: detail, severity: severity,
                coverage: coverage, hasPacket: hasPacket, confirmedAt: confirmedAt, retryAt: retryAt)
        }
        if !enabled { return make(.disabled, "地图已关闭", "可在圆屏设置中开启地图", .neutral) }
        if !usesBasemap { return make(.notRequired, "雷达风格无需底图", "路线和位置仍会发送到圆屏", .good) }
        switch preparation {
        case .failed(let message, let retryAt):
            return make(.retrying, "地图更新失败，等待重试", "\(retained)；\(message)", .attention, retryAt: retryAt)
        case .waitingForeground:
            return make(.waitingForeground, "回到前台继续准备地图", retained, .attention)
        case .preparing:
            return make(.preparing, "正在准备下一块地图", retained, .progress)
        case .idle: break
        }
        if hasPacket && !connected { return make(.waitingConnection, "地图已备好，等待连接圆屏", "连接后重新发送并确认地图", .attention) }
        switch delivery {
        case .transmitting: return make(.transferring, "正在更新圆屏地图", retained, .progress)
        case .prepared: return make(.idle, "地图已准备好", "\(retained)；开始导航后发送", .neutral)
        case .waitingConnection: return make(.waitingConnection, "地图已备好，等待重新发送", retained, .progress)
        case .confirmed:
            switch coverage {
            case .covered: return make(.confirmed, "圆屏地图覆盖当前位置", "圆屏已确认收到地图", .good)
            case .uncovered: return make(.stale, "需要更新当前位置地图", retained, .attention)
            case .unknown: return make(.confirmed, "圆屏已收到地图，等待定位", "定位后核对地图覆盖范围", .neutral)
            case .unconfirmed: return make(.stale, "等待圆屏重新确认地图", retained, .attention)
            }
        case .none: return make(.idle, "导航时自动准备地图", "选择路线后可提前准备沿线地图", .neutral)
        }
    }
}

/// Progress is carried as counts and phases, never recovered from user-facing text.
struct RouteMapPreparation: Equatable {
    enum Phase: String { case none, checking, preparing, paused, retrying, complete, failed, storageBlocked, memoryBlocked, configurationBlocked, rateLimited }
    let phase: Phase
    let ready: Int
    let total: Int
    let detailedReady: Int
    let retryAt: Date?
    let error: String?
    let detail: String
    var freshReady: Int = 0
    var oldestGeneratedAt: Date? = nil
    /// Counts above describe only this preparation window; zero range means the whole route.
    var rangeKm: Int = 0
    var routeTotal: Int = 0
    var failedCount: Int = 0
    var failureCategory: String? = nil
    var hasPlan: Bool { phase != .none }
    /// Basic maps are sufficient for departure; building enrichment may continue later.
    var isComplete: Bool { total > 0 && ready >= total }
    var isDetailedComplete: Bool { total > 0 && detailedReady >= total }
    var isFreshComplete: Bool { total > 0 && freshReady >= total }
    var fraction: Double { total > 0 ? min(1, max(0, Double(ready) / Double(total))) : 0 }
    var title: String {
        switch phase {
        case .none: return "选择路线后准备沿线地图"
        case .checking: return "正在检查沿线缓存"
        case .complete: return rangeKm == 0 ? "全程地图已准备完成" : "前方 \(rangeKm) 公里地图已准备完成"
        case .failed: return "沿线地图准备失败"
        case .storageBlocked: return "沿线准备已暂停，请清理存储空间"
        case .memoryBlocked: return "内存紧张，沿线预取已暂停"
        case .configurationBlocked: return "地图配置或授权需要检查"
        case .rateLimited: return "地图服务冷却中，已有地图仍可使用"
        case .retrying: return "沿线地图等待重试：\(ready)/\(total) 块可用"
        case .paused: return "沿线准备已暂停：\(ready)/\(total) 块可用"
        case .preparing: return isComplete ? "沿线底图可用，正在更新或补齐细节" : "沿线地图：\(ready)/\(total) 块可用"
        }
    }
    static let none = RouteMapPreparation(phase: .none, ready: 0, total: 0, detailedReady: 0, retryAt: nil, error: nil, detail: "保持 App 前台可提前准备沿线地图")
}
