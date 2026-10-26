import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Only the requested map work is saved. A checkpoint is never navigation state:
/// it contains no GPS fix, along-route progress, guidance, timers or display ACKs.
struct PreparationRecoveryCheckpoint: Codable, Equatable {
    struct Point: Codable, Equatable { let lat: Double, lng: Double }
    static let maximumAge: TimeInterval = 7 * 24 * 3600
    static let maximumPoints = 20_000
    var version = 1
    var id = UUID()
    var savedAt: Date
    var key: String
    var points: [Point]
    var frameLat: Double, frameLng: Double
    var frameID: Int
    var source: Int, style: Int
    var buildings: Bool
    /// User choice and effective work differ when no display capability has been
    /// negotiated. Restore checks the choice, then reuses the saved work variant.
    var buildingPreference = false
    var rangeKm: Int
    var forceRefresh: Bool
    var refreshStartedAt: Date

    func isValid(at now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt), refreshAge = now.timeIntervalSince(refreshStartedAt)
        return version == 1 && age.isFinite && (-300...Self.maximumAge).contains(age) &&
            refreshAge.isFinite && (-300...Self.maximumAge).contains(refreshAge) &&
            !key.isEmpty && key.utf8.count <= 512 && (2...Self.maximumPoints).contains(points.count) &&
            Self.valid(lat: frameLat, lng: frameLng) && (1...32767).contains(frameID) && source == 3 &&
            [0, 1, 2, 5].contains(style) && (!buildings || (style == 1 && buildingPreference)) && [0, 5, 20, 50].contains(rangeKm) &&
            points.allSatisfy { Self.valid(lat: $0.lat, lng: $0.lng) }
    }
    private static func valid(lat: Double, lng: Double) -> Bool {
        lat.isFinite && lng.isFinite && (-85...85).contains(lat) && (-180...180).contains(lng)
    }
    func matches(source: Int, style: Int, buildingPreference: Bool) -> Bool {
        self.source == source && self.style == style && self.buildingPreference == buildingPreference
    }
    var styleName: String {
        switch style { case 0: return "原版"; case 1: return "罪恶都市"; case 2: return "GTA5"; case 5: return "极简黑白"; default: return "地图" }
    }
}

/// One bounded, private checkpoint. Disk work runs on a single utility queue;
/// updates replace its pending snapshot instead of creating one job per update.
/// Owners are invalidated immediately on cancel/replacement, including late callbacks.
final class PreparationRecoveryStore {
    static let maximumBytes = 2 * 1024 * 1024
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MotoNav", isDirectory: true).appendingPathComponent("map-preparation.json")
    }
    private struct Mutation { let revision: UInt64; let checkpoint: PreparationRecoveryCheckpoint? }
    private let queue = DispatchQueue(label: "motonav.preparation.recovery", qos: .utility)
    private let lock = NSLock(), now: () -> Date
    private let beforeCommit: () -> Void
    let url: URL
    private var owner = UUID(), revision: UInt64 = 0
    private var pending: Mutation?, scheduled = false, writes = 0
    init(url: URL = PreparationRecoveryStore.defaultURL, now: @escaping () -> Date = Date.init,
         beforeCommit: @escaping () -> Void = {}) {
        self.url = url; self.now = now; self.beforeCommit = beforeCommit
    }
    var pendingWriteCount: Int { lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1 }
    var successfulWriteCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    @discardableResult func begin(_ checkpoint: PreparationRecoveryCheckpoint) -> UUID {
        lock.lock(); owner = UUID(); let current = owner
        enqueueLocked(checkpoint); lock.unlock(); return current
    }
    @discardableResult func update(_ checkpoint: PreparationRecoveryCheckpoint, owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == self.owner else { return false }
        enqueueLocked(checkpoint); return true
    }
    func clear(owner: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let owner = owner, owner != self.owner { return }
        self.owner = UUID(); enqueueLocked(nil)
    }
    private func enqueueLocked(_ checkpoint: PreparationRecoveryCheckpoint?) {
        revision &+= 1; pending = Mutation(revision: revision, checkpoint: checkpoint)
        if !scheduled { scheduled = true; queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else { scheduled = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            guard let checkpoint = next.checkpoint else {
                lock.lock()
                if next.revision == revision {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: url.appendingPathExtension("pending"))
                }
                lock.unlock(); continue
            }
            guard checkpoint.isValid(at: now()), let data = try? JSONEncoder().encode(checkpoint),
                  data.count <= Self.maximumBytes else {
                lock.lock()
                if next.revision == revision { try? FileManager.default.removeItem(at: url) }
                lock.unlock(); continue
            }
            lock.lock(); let current = next.revision == revision; lock.unlock()
            guard current else { continue }
            // A process crash can leave at most this one private staging file.
            // The next attempt reuses it; unrelated files are never enumerated.
            let temporary = url.appendingPathExtension("pending")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                #if os(iOS)
                try data.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: temporary)
                #endif
                beforeCommit()
                // Only the short atomic rename holds this lock. A replacement or
                // cancel during serialization/write invalidates this snapshot.
                lock.lock()
                if next.revision == revision {
                    let result = temporary.path.withCString { source in url.path.withCString { target in rename(source, target) } }
                    if result == 0 { writes += 1 }
                }
                lock.unlock()
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var local = url; try? local.setResourceValues(values)
            } catch { /* Map maintenance persistence never blocks navigation. */ }
        }
    }
    /// Call on a worker or from a test; production uses loadAsync below.
    func load() -> PreparationRecoveryCheckpoint? {
        // The single production store calls this on its serial worker before
        // preparing writes. Remove exactly our interrupted staging file only.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pending"))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue > 0,
                  size.intValue <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(PreparationRecoveryCheckpoint.self, from: data)
            guard value.isValid(at: now()) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        } catch { try? FileManager.default.removeItem(at: url); return nil }
    }
    /// Loading cannot overwrite a newer task selected while disk I/O was in flight.
    func loadAsync(_ completion: @escaping (PreparationRecoveryCheckpoint?) -> Void) {
        lock.lock(); let expected = revision; lock.unlock()
        queue.async {
            let value = self.load()
            DispatchQueue.main.async {
                self.lock.lock(); let current = self.revision == expected; self.lock.unlock()
                if current { completion(value) }
            }
        }
    }
    func flushForTests() { queue.sync {} }
}
