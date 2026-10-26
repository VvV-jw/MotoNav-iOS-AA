import Foundation

/// Shared provider boundary: cached fallback can succeed without bypassing HTTP cooldown.
/// The clock and fetch closure are injectable for deterministic, device-free replay.
final class GtaServiceGate {
    private let lock = NSLock(), now: () -> Date
    private var deadline: Date?, status = 429
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    var retryAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return deadline.flatMap { $0 > now() ? $0 : nil }
    }
    private func check() throws {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        if let deadline = deadline, deadline > current {
            throw MapServiceError.http(status: status, retryAfter: deadline.timeIntervalSince(current))
        }
    }
    func fetch<T>(_ work: () throws -> T) throws -> T {
        // Gate rejections must never re-enter the response branch and extend the deadline.
        try check()
        do { return try work() }
        catch {
            if case MapServiceError.http(let status, let retryAfter) = error, status == 429 || status == 503 {
                let seconds = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 60
                let until = now().addingTimeInterval(max(1, seconds))
                lock.lock()
                if until > (deadline ?? .distantPast) { deadline = until; self.status = status }
                let recorded = deadline!, recordedStatus = self.status
                lock.unlock()
                throw MapServiceError.http(status: recordedStatus, retryAfter: max(0, recorded.timeIntervalSince(now())))
            }
            throw error
        }
    }
}
