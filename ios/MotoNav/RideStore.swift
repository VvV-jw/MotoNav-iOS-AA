import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RideFix: Codable, Equatable {
    let lat: Double, lng: Double, time: Date, speed: Double
    var startsSegment = false
    var isValid: Bool {
        lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng) &&
        time.timeIntervalSince1970.isFinite && (0...16_725_225_600).contains(time.timeIntervalSince1970) &&
        speed.isFinite && (0...150).contains(speed)
    }
    static func distance(_ a: RideFix, _ b: RideFix) -> Double {
        let p = Double.pi / 180, dlat = (b.lat - a.lat) * p, dlng = (b.lng - a.lng) * p
        let h = pow(sin(dlat / 2), 2) + cos(a.lat * p) * cos(b.lat * p) * pow(sin(dlng / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

/// Constant-size recording state. Lost/inaccurate fixes and long gaps start a new
/// segment, so a tunnel, stopped recorder or rejected jump never becomes a road.
struct RideRecordingPolicy {
    static let segmentGap: TimeInterval = 30
    private(set) var last: RideFix?
    private var needsSegment = true
    mutating func noteGap() { needsSegment = true }
    mutating func accept(_ input: RideFix, accuracy: Double, now: Date) -> RideFix? {
        let age = now.timeIntervalSince(input.time)
        guard input.isValid, accuracy.isFinite, (0...60).contains(accuracy), age.isFinite, (-5...15).contains(age) else {
            needsSegment = true; return nil
        }
        var point = input
        if let previous = last {
            let seconds = point.time.timeIntervalSince(previous.time)
            guard seconds > 0 else { return nil }
            let distance = RideFix.distance(previous, point)
            if !needsSegment, seconds <= Self.segmentGap, distance / seconds >= 90 {
                needsSegment = true; return nil
            }
            guard needsSegment || seconds > Self.segmentGap || distance >= 3 || seconds >= 10 else { return nil }
            point.startsSegment = needsSegment || seconds > Self.segmentGap
        } else { point.startsSegment = true }
        last = point; needsSegment = false; return point
    }
}

/// History and live UI keep metadata only. No complete track is retained here.
struct RideSummary: Codable, Identifiable, Equatable {
    var version = 1
    var id = UUID()
    let started: Date
    var ended: Date?
    var mode: String
    var pointCount = 0
    var meters = 0.0
    var segments = 0
    var recovered = false
    var legacyFile: String?
    var readProblem = false
    private enum CodingKeys: String, CodingKey {
        case version, id, started, ended, mode, pointCount, meters, segments, recovered, legacyFile
    }
    var valid: Bool {
        version == 1 && started.timeIntervalSince1970.isFinite && (0...16_725_225_600).contains(started.timeIntervalSince1970) &&
        (ended == nil || (ended!.timeIntervalSince1970.isFinite && ended! >= started && ended!.timeIntervalSince1970 <= 16_725_225_600)) &&
        !mode.isEmpty && mode.utf8.count <= 256 && pointCount >= 0 && segments >= 0 && segments <= pointCount &&
        meters.isFinite && (0...1_000_000_000_000).contains(meters) && (legacyFile == nil || legacyFile == id.uuidString + ".json") &&
        mode.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13 || (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        }
    }
}

enum RideStoreFailure: String, Error, Hashable {
    case storage, corrupt, legacyTooLarge, legacyInvalid, busy, staleSession
    var message: String {
        switch self {
        case .storage: return "轨迹文件暂时无法读写，请检查存储空间；已有记录保留，导航照常进行。"
        case .corrupt: return "部分轨迹数据损坏，原文件已保留；未生成不完整的导出文件。"
        case .legacyTooLarge: return "有旧版轨迹超过安全整理上限，原 JSON 文件已保留；不会自动删除。"
        case .legacyInvalid: return "有旧版轨迹无法完整读取，原 JSON 文件已保留；不会自动删除。"
        case .busy: return "轨迹保存暂时繁忙，漏记处会分段，已有记录保留；导航照常进行。"
        case .staleSession: return "此轨迹已结束或删除，未写入其他行程。"
        }
    }
}

/// One private FIFO worker owns file handles, migration, recovery and GPX export.
/// Accepted fixes are append-only NDJSON; small metadata is written at begin/end,
/// not once per fix. The pending point queue and every streaming buffer are bounded.
final class RideStore {
    struct Cursor: Equatable { let started: Date, id: UUID }
    struct Page {
        let rides: [RideSummary], next: Cursor?
        let isMigrating: Bool, retainedLegacy: Int, legacyFailures: [RideStoreFailure]
    }
    struct Limits {
        var queuedOperations = 1024
        var reservedControls = 32
        var legacyBytes = 16 * 1024 * 1024
        var legacyPoints = 200_000
        var pageSize = 40
    }
    private struct Job { let point: Bool; let run: () -> Void }
    private struct Session { var summary: RideSummary; var last: RideFix?; let handle: FileHandle }
    private struct LegacyFix: Codable { let lat: Double, lng: Double, time: Date, speed: Double }
    private struct LegacyRide: Codable {
        let id: UUID, started: Date, ended: Date?, mode: String
        let fixes: [LegacyFix]
        let meters: Double
    }
    private final class LegacyWork {
        let legacy: LegacyRide, stage: URL, output: FileHandle
        var summary: RideSummary, index = 0, last: RideFix?
        init(legacy: LegacyRide, stage: URL, output: FileHandle, summary: RideSummary) {
            self.legacy = legacy; self.stage = stage; self.output = output; self.summary = summary
        }
    }
    private let queue = DispatchQueue(label: "motonav.rides.store", qos: .utility)
    private let lock = NSLock()
    private var pending: [Job] = [], draining = false
    private var observerScheduled = false
    private var pendingFailure: (UUID?, RideStoreFailure)?
    private var failureObserver: ((UUID?, RideStoreFailure) -> Void)?
    private var catalogObserver: (() -> Void)?
    private var catalogScheduled = false
    private var current: Session?
    private var ready = false
    private var migration: FileManager.DirectoryEnumerator?
    private var migrationScheduled = false
    private var migrationSinceNotice = 0
    private var migrationWork: LegacyWork?
    private var retainedLegacy = 0
    private var legacyFailures = Set<RideStoreFailure>()
    private(set) var maximumPendingOperations = 0
    private(set) var maximumReadBuffer = 0
    private let now: () -> Date
    private let beforeWrite: (String) throws -> Void
    let root: URL
    let limits: Limits

    init(root: URL, limits: Limits = Limits(), now: @escaping () -> Date = Date.init,
         beforeWrite: @escaping (String) throws -> Void = { _ in }) {
        self.root = root; self.limits = limits; self.now = now; self.beforeWrite = beforeWrite
    }
    var pendingOperationCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func observeFailures(_ callback: @escaping (UUID?, RideStoreFailure) -> Void) {
        lock.lock(); failureObserver = callback; lock.unlock()
    }
    func observeCatalog(_ callback: @escaping () -> Void) {
        lock.lock(); catalogObserver = callback; lock.unlock()
    }
    private func report(_ id: UUID?, _ failure: RideStoreFailure) {
        lock.lock(); pendingFailure = (id, failure)
        guard failureObserver != nil, !observerScheduled else { lock.unlock(); return }
        observerScheduled = true; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); let value = self.pendingFailure, callback = self.failureObserver
            self.pendingFailure = nil; self.observerScheduled = false; self.lock.unlock()
            if let value = value { callback?(value.0, value.1) }
        }
    }
    private func catalogChanged() {
        lock.lock()
        guard catalogObserver != nil, !catalogScheduled else { lock.unlock(); return }
        catalogScheduled = true; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.catalogScheduled = false; let callback = self.catalogObserver; self.lock.unlock()
            callback?()
        }
    }
    @discardableResult private func enqueue(point: Bool = false, _ run: @escaping () -> Void) -> Bool {
        lock.lock()
        let cap = max(1, limits.queuedOperations) + (point ? 0 : max(1, limits.reservedControls))
        guard pending.count < cap else { lock.unlock(); return false }
        pending.append(Job(point: point, run: run)); maximumPendingOperations = max(maximumPendingOperations, pending.count)
        if !draining { draining = true; queue.async { self.drain() } }
        lock.unlock(); return true
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { draining = false; lock.unlock(); return }
            let job = pending.removeFirst(); lock.unlock(); job.run()
        }
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".ride", isDirectory: true) }
    private func tombstone(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".deleted") }
    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !ready {
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            var resource = root, values = URLResourceValues(); values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
            #endif
            ready = true
            migration = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            scheduleMigration()
        }
    }
    private func write(_ summary: RideSummary, at folder: URL) throws {
        guard summary.valid else { throw RideStoreFailure.corrupt }
        try beforeWrite("metadata")
        let data = try JSONEncoder().encode(summary)
        #if os(iOS)
        try data.write(to: folder.appendingPathComponent("metadata.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        #endif
    }
    private func readSummary(_ folder: URL) throws -> RideSummary {
        let file = folder.appendingPathComponent("metadata.json")
        let value = try JSONDecoder().decode(RideSummary.self, from: boundedData(file, maximum: 16_384))
        guard value.valid, folder.lastPathComponent == value.id.uuidString + ".ride" else { throw RideStoreFailure.corrupt }
        return value
    }
    private func boundedData(_ file: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let value = try handle.read(upToCount: maximum + 1) ?? Data()
        guard !value.isEmpty, value.count <= maximum else { throw RideStoreFailure.corrupt }
        return value
    }
    private func create(_ summary: RideSummary, folder: URL) throws -> FileHandle {
        guard summary.valid, !FileManager.default.fileExists(atPath: folder.path), !FileManager.default.fileExists(atPath: tombstone(summary.id).path) else { throw RideStoreFailure.staleSession }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try write(summary, at: folder)
            let points = folder.appendingPathComponent("points.ndjson")
            guard FileManager.default.createFile(atPath: points.path, contents: nil) else { throw RideStoreFailure.storage }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: points.path)
            #endif
            return try FileHandle(forWritingTo: points)
        } catch {
            // Only a newly created, unpublished directory belongs to this attempt.
            // It may already contain a valid header, so leave it for recovery.
            throw error
        }
    }
    @discardableResult func begin(_ summary: RideSummary, completion: ((Result<RideSummary, RideStoreFailure>) -> Void)? = nil) -> Bool {
        let accepted = enqueue {
            do {
                try self.ensureRoot()
                if let old = self.current { try self.finishCurrent(at: max(summary.started, old.summary.started)) }
                let handle = try self.create(summary, folder: self.directory(summary.id))
                self.current = Session(summary: summary, last: nil, handle: handle)
                completion?(.success(summary)); self.catalogChanged()
            } catch { let failure = self.failure(error); self.report(summary.id, failure); completion?(.failure(failure)) }
        }
        if !accepted { report(summary.id, .busy); completion?(.failure(.busy)) }
        return accepted
    }
    @discardableResult func append(_ point: RideFix, to id: UUID) -> Bool {
        let accepted = enqueue(point: true) {
            guard var session = self.current, session.summary.id == id else { return }
            do {
                guard point.isValid, session.last == nil || point.time > session.last!.time else { throw RideStoreFailure.corrupt }
                var point = point
                if session.last == nil || point.time.timeIntervalSince(session.last!.time) > RideRecordingPolicy.segmentGap { point.startsSegment = true }
                try self.beforeWrite("point")
                var data = try JSONEncoder().encode(point); data.append(10)
                try session.handle.write(contentsOf: data)
                Self.include(point, in: &session.summary, last: session.last)
                session.last = point; self.current = session
            } catch {
                // Pause this owner after a write error. A partial tail is recovered
                // on next launch; a later fix never appends past a corrupt record.
                try? session.handle.close(); self.current = nil
                self.report(id, self.failure(error)); self.catalogChanged()
            }
        }
        if !accepted { report(id, .busy) }
        return accepted
    }
    private static func include(_ point: RideFix, in summary: inout RideSummary, last: RideFix?) {
        summary.pointCount += 1
        if point.startsSegment || last == nil { summary.segments += 1 }
        else if let last = last { summary.meters += RideFix.distance(last, point) }
    }
    private func finishCurrent(at date: Date) throws {
        guard var session = current else { return }
        // Always close this owner's handle, even if the metadata write fails.
        defer { try? session.handle.close(); current = nil }
        try beforeWrite("finish")
        try session.handle.synchronize()
        session.summary.ended = max(session.summary.started, max(date, session.last?.time ?? session.summary.started))
        try write(session.summary, at: directory(session.summary.id))
    }
    @discardableResult func finish(_ id: UUID, at date: Date, completion: ((Result<Void, RideStoreFailure>) -> Void)? = nil) -> Bool {
        let accepted = enqueue {
            do {
                if self.current?.summary.id == id { try self.finishCurrent(at: date) }
                completion?(.success(())); self.catalogChanged()
            } catch { let failure = self.failure(error); self.report(id, failure); completion?(.failure(failure)) }
        }
        if !accepted { report(id, .busy); completion?(.failure(.busy)) }
        return accepted
    }
    @discardableResult func remove(_ id: UUID, completion: @escaping (Result<Void, RideStoreFailure>) -> Void) -> Bool {
        let accepted = enqueue {
            do {
                try self.ensureRoot(); try self.beforeWrite("delete")
                if self.current?.summary.id == id { try? self.current?.handle.close(); self.current = nil }
                // Durable tombstone precedes both removals. Interrupted deletion
                // must not allow a retained legacy JSON to resurrect the ride.
                try Data().write(to: self.tombstone(id), options: .atomic)
                let folder = self.directory(id), legacy = self.root.appendingPathComponent(id.uuidString + ".json")
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
                completion(.success(())); self.catalogChanged()
            } catch { let failure = self.failure(error); self.report(id, failure); completion(.failure(failure)) }
        }
        if !accepted { report(id, .busy); completion(.failure(.busy)) }
        return accepted
    }
    private func failure(_ error: Error) -> RideStoreFailure { error as? RideStoreFailure ?? .storage }
    private func newer(_ a: RideSummary, than b: RideSummary) -> Bool {
        a.started == b.started ? a.id.uuidString > b.id.uuidString : a.started > b.started
    }
    /// Only the newest page of metadata is kept, never every ride's point array.
    /// Cursor pages replace the UI list, so an arbitrarily long history stays bounded.
    @discardableResult func page(before cursor: Cursor? = nil, completion: @escaping (Result<Page, RideStoreFailure>) -> Void) -> Bool {
        let accepted = enqueue {
            do {
                try self.ensureRoot()
                var values = [RideSummary]()
                let size = min(100, max(1, self.limits.pageSize))
                let entries = FileManager.default.enumerator(at: self.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                while let folder = entries?.nextObject() as? URL {
                    guard folder.pathExtension == "ride" else { continue }
                    do {
                        var summary = try self.readSummary(folder)
                        guard !FileManager.default.fileExists(atPath: self.tombstone(summary.id).path), self.current?.summary.id != summary.id else { continue }
                        if summary.ended == nil {
                            do { summary = try self.recover(summary, folder: folder) }
                            catch { summary.readProblem = true; self.report(summary.id, self.failure(error)) }
                        }
                        if let cursor = cursor {
                            guard summary.started < cursor.started || (summary.started == cursor.started && summary.id.uuidString < cursor.id.uuidString) else { continue }
                        }
                        values.append(summary); values.sort { self.newer($0, than: $1) }
                        if values.count > size + 1 { values.removeLast() }
                    } catch { self.report(nil, self.failure(error)) }
                }
                let more = values.count > size
                if more { values.removeLast() }
                let next = more ? values.last.map { Cursor(started: $0.started, id: $0.id) } : nil
                completion(.success(Page(rides: values, next: next, isMigrating: self.migration != nil || self.migrationWork != nil,
                    retainedLegacy: self.retainedLegacy, legacyFailures: self.legacyFailures.sorted { $0.rawValue < $1.rawValue })))
            } catch { let failure = self.failure(error); self.report(nil, failure); completion(.failure(failure)) }
        }
        if !accepted { report(nil, .busy); completion(.failure(.busy)) }
        return accepted
    }
    private func recover(_ summary: RideSummary, folder: URL) throws -> RideSummary {
        var value = summary; value.pointCount = 0; value.meters = 0; value.segments = 0
        let result = try scan(folder.appendingPathComponent("points.ndjson"), repairTail: true) { point, last in
            Self.include(point, in: &value, last: last)
        }
        value.recovered = true; value.ended = max(value.started, result.last?.time ?? value.started)
        try write(value, at: folder); return value
    }
    private struct ScanResult { let last: RideFix?; let count: Int }
    /// Reads at most one 64 KiB chunk plus one bounded record. A crash-truncated
    /// final record is removed only while recovering an unfinished session.
    private func scan(_ file: URL, repairTail: Bool, each: (RideFix, RideFix?) throws -> Void) throws -> ScanResult {
        let reader = try RideLineReader(file)
        defer { reader.close(); maximumReadBuffer = max(maximumReadBuffer, reader.maximumBuffer) }
        var last: RideFix?, count = 0, validBytes: UInt64 = 0
        while let line = try reader.next() {
            if !line.complete {
                guard repairTail else { throw RideStoreFailure.corrupt }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.truncate(atOffset: validBytes); try handle.synchronize(); break
            }
            guard !line.data.isEmpty, let point = try? JSONDecoder().decode(RideFix.self, from: line.data), point.isValid,
                  last == nil || point.time > last!.time else { throw RideStoreFailure.corrupt }
            guard count > 0 || point.startsSegment else { throw RideStoreFailure.corrupt }
            if let last = last, point.time.timeIntervalSince(last.time) > RideRecordingPolicy.segmentGap, !point.startsSegment { throw RideStoreFailure.corrupt }
            try each(point, last); last = point; count += 1; validBytes = line.endOffset
        }
        return ScanResult(last: last, count: count)
    }
    @discardableResult func export(_ id: UUID, to exports: URL, completion: @escaping (Result<URL, RideStoreFailure>) -> Void) -> Bool {
        let accepted = enqueue {
            var temporary: URL?
            do {
                try self.ensureRoot()
                guard !FileManager.default.fileExists(atPath: self.tombstone(id).path) else { throw RideStoreFailure.staleSession }
                let folder = self.directory(id), summary = try self.readSummary(folder)
                try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
                let target = exports.appendingPathComponent("MotoNav-\(id.uuidString).gpx")
                let staging = exports.appendingPathComponent("MotoNav-\(id.uuidString).gpx.pending"); temporary = staging
                guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw RideStoreFailure.storage }
                let output = try FileHandle(forWritingTo: staging)
                defer { try? output.close() }
                func put(_ value: String) throws { try self.beforeWrite("export"); try output.write(contentsOf: Data(value.utf8)) }
                let formatter = ISO8601DateFormatter()
                try put("<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"MotoNav\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(Self.xml(summary.mode))</name>")
                var open = false
                let scanned = try self.scan(folder.appendingPathComponent("points.ndjson"), repairTail: false) { point, _ in
                    if !open || point.startsSegment { if open { try put("</trkseg>") }; try put("<trkseg>"); open = true }
                    try put("<trkpt lat=\"\(point.lat)\" lon=\"\(point.lng)\"><time>\(formatter.string(from: point.time))</time></trkpt>")
                }
                guard self.current?.summary.id == id || scanned.count == summary.pointCount else { throw RideStoreFailure.corrupt }
                if open { try put("</trkseg>") }
                try put("</trk></gpx>"); try output.synchronize(); try output.close()
                let result = staging.path.withCString { a in target.path.withCString { b in rename(a, b) } }
                guard result == 0 else { throw RideStoreFailure.storage }
                temporary = nil; completion(.success(target))
            } catch {
                if let temporary = temporary { try? FileManager.default.removeItem(at: temporary) }
                let failure = self.failure(error); self.report(id, failure); completion(.failure(failure))
            }
        }
        if !accepted { report(id, .busy); completion(.failure(.busy)) }
        return accepted
    }
    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private func scheduleMigration() {
        guard migration != nil || migrationWork != nil, !migrationScheduled else { return }
        migrationScheduled = true
        queue.async { self.migrateNext() }
    }
    private func migrateNext() {
        migrationScheduled = false
        if let work = migrationWork {
            do {
                if FileManager.default.fileExists(atPath: tombstone(work.summary.id).path) {
                    try? work.output.close(); try? FileManager.default.removeItem(at: work.stage)
                    migrationWork = nil; scheduleMigration(); return
                }
                if try advanceMigration(work) {
                    migrationWork = nil; migrationSinceNotice += 1
                    if migrationSinceNotice >= 8 { migrationSinceNotice = 0; catalogChanged() }
                }
            } catch {
                try? work.output.close(); try? FileManager.default.removeItem(at: work.stage)
                migrationWork = nil; retainLegacy(work.summary.id, failure(error))
            }
            scheduleMigration(); return
        }
        while let file = migration?.nextObject() as? URL {
            guard file.pathExtension == "json" else { continue }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                retainLegacy(nil, .legacyInvalid); scheduleMigration(); return
            }
            guard !FileManager.default.fileExists(atPath: directory(id).path), !FileManager.default.fileExists(atPath: tombstone(id).path) else { continue }
            do { migrationWork = try beginMigration(file, id: id) }
            catch { retainLegacy(id, failure(error)) }
            // Decode at most one bounded old file, then write at most 512 points
            // per worker turn. Fresh navigation jobs run between conversion batches.
            scheduleMigration(); return
        }
        migration = nil; catalogChanged()
    }
    private func retainLegacy(_ id: UUID?, _ reason: RideStoreFailure) {
        retainedLegacy += 1; legacyFailures.insert(reason); report(id, reason)
    }
    private func beginMigration(_ file: URL, id: UUID) throws -> LegacyWork {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard bytes <= max(1, limits.legacyBytes) else { throw RideStoreFailure.legacyTooLarge }
        let legacy: LegacyRide
        do { legacy = try JSONDecoder().decode(LegacyRide.self, from: boundedData(file, maximum: max(1, limits.legacyBytes))) }
        catch { throw RideStoreFailure.legacyInvalid }
        guard legacy.id == id, legacy.fixes.count <= max(0, limits.legacyPoints) else { throw RideStoreFailure.legacyTooLarge }
        let summary = RideSummary(id: id, started: legacy.started, ended: legacy.ended, mode: legacy.mode, legacyFile: file.lastPathComponent)
        guard summary.valid else { throw RideStoreFailure.legacyInvalid }
        let stage = root.appendingPathComponent(".migrating-" + id.uuidString, isDirectory: true)
        // A previous crash left only this private staging path. The original JSON
        // remains untouched until the new journal is entirely published.
        if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let points = stage.appendingPathComponent("points.ndjson")
        guard FileManager.default.createFile(atPath: points.path, contents: nil) else { throw RideStoreFailure.storage }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: points.path)
        #endif
        let output = try FileHandle(forWritingTo: points)
        return LegacyWork(legacy: legacy, stage: stage, output: output, summary: summary)
    }
    private func advanceMigration(_ work: LegacyWork) throws -> Bool {
        let end = min(work.legacy.fixes.count, work.index + 512)
        while work.index < end {
            let old = work.legacy.fixes[work.index]
            var point = RideFix(lat: old.lat, lng: old.lng, time: old.time, speed: old.speed)
            guard point.isValid, work.last == nil || point.time > work.last!.time else { throw RideStoreFailure.legacyInvalid }
            point.startsSegment = work.last == nil || point.time.timeIntervalSince(work.last!.time) > RideRecordingPolicy.segmentGap
            if let previous = work.last, RideFix.distance(previous, point) / point.time.timeIntervalSince(previous.time) >= 90 { point.startsSegment = true }
            var bytes = try JSONEncoder().encode(point); bytes.append(10)
            try beforeWrite("migration"); try work.output.write(contentsOf: bytes)
            Self.include(point, in: &work.summary, last: work.last); work.last = point; work.index += 1
        }
        guard work.index == work.legacy.fixes.count else { return false }
        work.summary.ended = max(work.summary.started, max(work.summary.ended ?? work.summary.started, work.last?.time ?? work.summary.started))
        work.summary.recovered = work.legacy.ended == nil
        try work.output.synchronize(); try work.output.close(); try write(work.summary, at: work.stage)
        try FileManager.default.moveItem(at: work.stage, to: directory(work.summary.id))
        // Keep the original legacy JSON as a compatibility backup. Its matching
        // published directory prevents duplicate migration on future launches.
        return true
    }
    func flushForTests() { queue.sync {} }
    func flushMigrationForTests() {
        for _ in 0..<10_000 { if queue.sync(execute: { migration == nil && migrationWork == nil }) { return } }
    }
    func closeForTests() {
        queue.sync {
            try? current?.handle.close(); current = nil
            try? migrationWork?.output.close(); migrationWork = nil; migration = nil
        }
    }
}

private final class RideLineReader {
    struct Line { let data: Data, complete: Bool, endOffset: UInt64 }
    private let handle: FileHandle
    private var buffer = Data(), cursor = 0, offset: UInt64 = 0, ended = false
    private(set) var maximumBuffer = 0
    init(_ file: URL) throws { handle = try FileHandle(forReadingFrom: file) }
    func close() { try? handle.close() }
    func next() throws -> Line? {
        while true {
            if let newline = buffer[cursor...].firstIndex(of: 10) {
                guard newline - cursor <= 1024 else { throw RideStoreFailure.corrupt }
                let value = buffer.subdata(in: cursor..<newline)
                offset += UInt64(newline - cursor + 1); cursor = newline + 1
                return Line(data: value, complete: true, endOffset: offset)
            }
            guard buffer.count - cursor <= 1024 else { throw RideStoreFailure.corrupt }
            if ended {
                guard cursor < buffer.count else { return nil }
                let value = buffer.subdata(in: cursor..<buffer.count); cursor = buffer.count
                return Line(data: value, complete: false, endOffset: offset + UInt64(value.count))
            }
            if cursor > 0 { buffer = Data(buffer[cursor...]); cursor = 0 }
            let next = try handle.read(upToCount: 64 * 1024) ?? Data()
            if next.isEmpty { ended = true } else { buffer.append(next); maximumBuffer = max(maximumBuffer, buffer.count) }
        }
    }
}
