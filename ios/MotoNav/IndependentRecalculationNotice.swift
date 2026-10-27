import Foundation

/// Presentation state only. This policy never schedules a retry, changes route
/// matching, or decides whether the existing navigator may start a request.
struct IndependentRecalculationNotice: Equatable {
    struct Ticket: Equatable {
        fileprivate let session: UInt64
        fileprivate let attempt: UInt64
    }
    struct Snapshot: Equatable {
        enum Phase: String { case failed, retrying }
        let phase: Phase
        let reason: String
        let remainingSeconds: Int?
        var title: String {
            phase == .retrying ? "正在重新规划，保留原路线" : "重算失败，保留原路线"
        }
        var detail: String { (phase == .retrying ? "上次失败：" : "失败原因：") + reason }
        var retryHint: String {
            if phase == .retrying { return "正在尝试更新路线；原路线继续保留。" }
            guard let seconds = remainingSeconds else { return "等待下一次有效定位与重算检查；原路线继续保留。" }
            if seconds > 0 { return "约 \(seconds) 秒后可再次重算；仍需满足偏航条件并取得有效定位。" }
            return "冷却已结束；满足偏航条件并取得有效定位后自动重算。"
        }
    }
    private struct Failure: Equatable {
        let reason: String
        let retryNotBefore: Date
    }
    private var session: UInt64 = 0
    private var attempt: UInt64 = 0
    private var pending: Ticket?
    private var failure: Failure?

    /// Explicit termination and accepted replacement candidates invalidate old
    /// presentation callbacks, independently of the navigation session token.
    mutating func resetSession() {
        session &+= 1; attempt = 0; pending = nil; failure = nil
    }
    mutating func beganAttempt() -> Ticket {
        attempt &+= 1
        let ticket = Ticket(session: session, attempt: attempt)
        pending = ticket
        return ticket
    }
    @discardableResult mutating func failed(_ reason: String, ticket: Ticket, retryNotBefore: Date) -> Bool {
        guard ticket == pending, ticket.session == session else { return false }
        let text = reason.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        failure = Failure(reason: text.isEmpty ? "路线服务未返回可用结果" : String(text.prefix(400)), retryNotBefore: retryNotBefore)
        pending = nil
        return true
    }
    @discardableResult mutating func succeeded(ticket: Ticket) -> Bool {
        guard ticket == pending, ticket.session == session else { return false }
        pending = nil; failure = nil
        return true
    }
    /// Call only after the existing tracker accepts a fresh fix on the original
    /// effective route. Ordinary off-route fixes and GPS warnings never call it.
    mutating func returnedToEffectiveRoute() {
        pending = nil; failure = nil
    }
    func snapshot(at now: Date) -> Snapshot? {
        guard let failure = failure else { return nil }
        let interval = failure.retryNotBefore.timeIntervalSince(now)
        let seconds: Int? = interval.isFinite && abs(interval) <= 86_400 ? Int(ceil(max(0, interval))) : nil
        return Snapshot(phase: pending == nil ? .failed : .retrying,
            reason: failure.reason, remainingSeconds: seconds)
    }
}
