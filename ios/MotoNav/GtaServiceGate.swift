import Foundation

/// Shared provider boundary: cached fallback can succeed without bypassing HTTP cooldown.
/// The clock and fetch closure are injectable for deterministic, device-free replay.
final class GtaServiceGate {
    static let maximumCooldown: TimeInterval = 7 * 24 * 3600
    static var defaultPersistenceURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MotoNav", isDirectory: true).appendingPathComponent("gta-service-cooldown.json")
    }
    private struct Record: Codable {
        var version = 1
        let observedAt: Date, retryAt: Date
        let status: Int
    }
    private let lock = NSLock(), persistenceLock = NSLock(), now: () -> Date
    private let persistenceURL: URL?
    private let beforePersistence: () -> Void
    private var loaded = false
    private var deadline: Date?, status = 429
    init(now: @escaping () -> Date = Date.init, persistenceURL: URL? = nil,
         beforePersistence: @escaping () -> Void = {}) {
        self.now = now; self.persistenceURL = persistenceURL; self.beforePersistence = beforePersistence
    }
    var retryAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return deadline.flatMap { $0 > now() ? $0 : nil }
    }
    private func check() throws {
        ensureLoaded()
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
                let current = now(), until = current.addingTimeInterval(min(Self.maximumCooldown, max(1, seconds)))
                lock.lock()
                var changed = false
                if until > (deadline ?? .distantPast) {
                    deadline = until; self.status = status; changed = true
                }
                lock.unlock()
                if changed { persistLatest() }
                lock.lock(); let recorded = deadline!, recordedStatus = self.status; lock.unlock()
                throw MapServiceError.http(status: recordedStatus, retryAfter: max(0, recorded.timeIntervalSince(now())))
            }
            throw error
        }
    }
    /// Provider workers serialize disk access separately. Main-thread retryAt
    /// readers only take the short RAM lock, even when private storage is slow.
    private func ensureLoaded() {
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        guard !loaded else { return }; loaded = true
        guard let url = persistenceURL else { return }
        beforePersistence()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let current = now()
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber, (1...4096).contains(size.intValue) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            let record = try JSONDecoder().decode(Record.self, from: data)
            let duration = record.retryAt.timeIntervalSince(record.observedAt)
            guard record.version == 1, [429, 503].contains(record.status), duration.isFinite,
                  duration > 0, duration <= Self.maximumCooldown,
                  record.observedAt.timeIntervalSince1970.isFinite,
                  record.retryAt.timeIntervalSince1970.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            // A clock rollback must not erase a real service cooldown. Normalize
            // once to the saved remaining duration, then persist the new anchor so
            // repeated restarts at the same clock cannot create a sliding delay.
            let remaining = min(duration, max(0, record.retryAt.timeIntervalSince(current)))
            if remaining > 0 {
                lock.lock()
                let restored = current.addingTimeInterval(remaining)
                if restored > (deadline ?? .distantPast) { deadline = restored; status = record.status }
                lock.unlock()
                if current < record.observedAt { writeLatest() }
            } else { try? FileManager.default.removeItem(at: url) }
        } catch { try? FileManager.default.removeItem(at: url) }
    }
    private func persistLatest() {
        guard persistenceURL != nil else { return }
        persistenceLock.lock(); defer { persistenceLock.unlock() }
        beforePersistence(); writeLatest()
    }
    /// persistenceLock is held, state lock is released before any disk operation.
    /// Snapshot after obtaining the disk lock, so delayed responses cannot write
    /// an older, shorter deadline over one that another response already extended.
    private func writeLatest() {
        let current = now()
        lock.lock()
        let record = deadline.map { Record(observedAt: current, retryAt: $0, status: status) }
        lock.unlock()
        guard let url = persistenceURL, let record = record,
              let data = try? JSONEncoder().encode(record) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var local = url; try? local.setResourceValues(values)
        } catch { /* Keep the in-process gate if private storage is unavailable. */ }
    }
}
