import Foundation

/// Match the round display's speed-dependent raster viewport (including its displaced arrow).
enum MapCoveragePolicy {
    static func radius(kmh: Int) -> Double {
        let scale = min(0.6, max(0.38, 0.85 - Double(max(0, kmh)) * 0.006))
        return 292 / scale
    }
    static func covers(x: Double, y: Double, cx: Double, cy: Double, kmh: Int, half: Double = 1200, margin: Double = 0) -> Bool {
        max(abs(x - cx), abs(y - cy)) + radius(kmh: kmh) + margin <= half
    }
    static func lookahead(kmh: Int, half: Double = 1200, preferred: Double = 450) -> Double {
        max(0, min(preferred, half - radius(kmh: kmh) - 180))
    }
    static func needsRefresh(x: Double, y: Double, cx: Double, cy: Double, bearing: Double, kmh: Int,
                             preparationSeconds: Double = 8, half: Double = 1200) -> Bool {
        // Leave time for rendering, processing and BLE delivery before the current map expires.
        let distance = Double(max(0, kmh)) / 3.6 * max(1, min(30, preparationSeconds))
        let angle = bearing * .pi / 180
        let viewSpeed = max(120, kmh) // Firmware zoom recovers gradually after slowing down.
        return !covers(x: x, y: y, cx: cx, cy: cy, kmh: viewSpeed, half: half, margin: 100) ||
            !covers(x: x + sin(angle) * distance, y: y + cos(angle) * distance,
                    cx: cx, cy: cy, kmh: viewSpeed, half: half, margin: 100)
    }
}

/// Samples the actual route every 600 m, with 800 m lookahead and overlapping 2.4 km blocks.
struct RouteMapPlan {
    struct Node: Equatable { let x: Double, y: Double, distance: Double }
    static let step = 600.0, half = 1200.0
    let points: [(x: Double, y: Double)], cumulative: [Double], length: Double
    private(set) var nodes: [Node] = []
    init(_ points: [(x: Double, y: Double)]) throws {
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw MapProcessingError.invalid("路线坐标无效") }
        self.points = points
        var cumulative = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count { cumulative[i] = cumulative[i-1] + hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y) }
        self.cumulative = cumulative; length = cumulative.last!
        guard length.isFinite, length / Self.step <= 20000 else { throw MapProcessingError.invalid("路线过长") }
        var s = 0.0
        while s < length { nodes.append(at(s)); s += Self.step }
        nodes.append(at(length))
    }
    func at(_ distance: Double) -> Node {
        let s = min(length, max(0, distance))
        var lo = 1, hi = cumulative.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if cumulative[mid] < s { lo = mid + 1 } else { hi = mid } }
        let span = cumulative[lo] - cumulative[lo-1], t = span == 0 ? 0 : (s - cumulative[lo-1]) / span
        let x = points[lo-1].x + (points[lo].x - points[lo-1].x) * t, y = points[lo-1].y + (points[lo].y - points[lo-1].y) * t
        return Node(x: (x / 2).rounded(.toNearestOrEven) * 2, y: (y / 2).rounded(.toNearestOrEven) * 2, distance: s)
    }
    func progress(x: Double, y: Double, previous: Double) -> Double {
        var best = Double.infinity, result = previous
        for i in 1..<points.count {
            if previous >= 0 && (cumulative[i] < previous - 150 || cumulative[i-1] > previous + 5000) { continue }
            let a = points[i-1], dx = points[i].x - a.x, dy = points[i].y - a.y, d = dx * dx + dy * dy
            let t = d == 0 ? 0 : min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / d))
            let error = hypot(x - a.x - dx * t, y - a.y - dy * t), s = cumulative[i-1] + (cumulative[i] - cumulative[i-1]) * t
            let score = error + (previous < 0 ? s * 1e-9 : abs(s - previous) * 1e-5)
            if score < best { best = score; result = s }
        }
        if best > 400, previous >= 0 { return progress(x: x, y: y, previous: -1) }
        return max(0, result)
    }
    func target(progress: Double, initial: Bool) -> Int {
        max(0, min(nodes.count - 1, Int(floor((progress + (initial ? Self.step / 2 : 800)) / Self.step))))
    }
    func displayTarget(progress: Double, x: Double, y: Double, kmh: Int) -> Int {
        let nearest = target(progress: progress, initial: true), next = min(nodes.count - 1, nearest + 1)
        // Switch to the next overlapping block as soon as it contains the full viewport.
        // Download lookahead alone must never choose a block that leaves the screen uncovered.
        if kmh > 5, next != nearest,
           MapCoveragePolicy.covers(x: x, y: y, cx: nodes[next].x, cy: nodes[next].y, kmh: max(120, kmh), margin: 50) {
            return next
        }
        return nearest
    }
}

/// Versioned, atomic map packets with one recoverable capacity index per cache instance.
/// Call disk operations on a worker queue. Packet reads/validation never hold the metadata lock.
final class RouteMapCache {
    struct Lookup {
        let data: Data
        /// Time this phone prepared the packet, not the underlying provider's road-data date.
        let generatedAt: Date
        let isStale: Bool
    }
    struct Stats {
        let bytes: Int64, limit: Int64, protectedBytes: Int64
        let files: Int, protectedFiles: Int
        let oldestGeneratedAt: Date?, newestGeneratedAt: Date?
        /// Diagnostic counter: stores and statistics must not enumerate the directory again.
        let diskScans: Int
    }
    enum CacheError: LocalizedError {
        case storageFull, capacityProtected, io(String)
        var isStorageBlocked: Bool {
            switch self { case .storageFull, .capacityProtected: return true; case .io: return false }
        }
        var errorDescription: String? {
            switch self {
            case .storageFull: return "手机存储空间不足，清理空间后可继续更新地图"
            case .capacityProtected: return "当前路线地图已占满缓存，请缩短离线准备范围或清理后重试"
            case .io(let text): return "地图缓存读写失败：\(text)"
            }
        }
    }
    private struct Entry: Codable {
        var bytes: Int64, generated: Double, accessed: Double, modified: Double
        var revision: UUID
    }
    private struct Index: Codable {
        let version: Int
        let entries: [String: Entry]
    }
    private struct Header {
        let generated: Double, length: Int, checksum: UInt64
    }
    static let metadataVersion = 2
    private static let magic: [UInt8] = [77, 78, 77, 67, 65, 67, 72, 69] // MNMCACHE
    private static let headerBytes = 32
    private let root: URL
    private let lock = NSLock(), operation = NSLock()
    private let limitBytes: Int64, minimumFreeBytes: Int64, maxAge: TimeInterval
    private let now: () -> Date, availableBytes: (URL) -> Int64?
    private var loaded = false, entries: [String: Entry] = [:], bytes: Int64 = 0
    private var protected: Set<String> = [], protectionOwner: UUID?
    private var diskScans = 0, pendingIndexChanges = 0
    static let shared = RouteMapCache()

    init(root: URL? = nil, limitBytes: Int64 = 512 * 1024 * 1024,
         minimumFreeBytes: Int64 = 32 * 1024 * 1024, maxAge: TimeInterval = 7 * 24 * 3600,
         now: @escaping () -> Date = Date.init,
         availableBytes: ((URL) -> Int64?)? = nil) {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("route_maps")).standardizedFileURL
        self.limitBytes = max(0, limitBytes); self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.maxAge = max(0, maxAge); self.now = now
        self.availableBytes = availableBytes ?? { url in
            guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                  let capacity = values.volumeAvailableCapacity else { return nil }
            return Int64(capacity)
        }
    }
    private var indexURL: URL { root.appendingPathComponent(".route-map-index-v2.json") }
    private func key(frame: MapGeo.Frame, source: Int, buildings: Bool, node: RouteMapPlan.Node, style: Int) -> String {
        let content = MapStylePolicy.cacheKey(theme: style, buildings: buildings)
        return "aa-styles-v1/\(content)/\(buildings && source == 3 ? "v2" : "v1")-\(source)-\(buildings ? "buildings" : "base")/\(frame.refLat)_\(frame.refLng)/\(Int(node.x))_\(Int(node.y)).bin"
    }
    private func valid(_ data: Data, frame: MapGeo.Frame, node: RouteMapPlan.Node, style: Int, buildings: Bool) -> Bool {
        let style = MapStylePolicy.normalize(style)
        if style == MapStylePolicy.gta5 {
            return !buildings && GtaVectorCodec.valid(data, frame: frame.id,
                cx: GtaVectorCodec.roundMeters(node.x), cy: GtaVectorCodec.roundMeters(node.y))
        }
        guard MapStylePolicy.usesAmapCapture(style), RasterPacket.isBuilding(data) == buildings,
              RasterPacket.valid(data, frame: frame.id, x: Int(node.x - 1200), y: Int(node.y + 1200)) else { return false }
        if style == MapStylePolicy.original { return !buildings && RasterPacket.hasPalette(data) }
        guard !RasterPacket.hasPalette(data) else { return false }
        return style != MapStylePolicy.minimal || !buildings
    }
    private static func checksum(_ data: Data) -> UInt64 {
        // Detect accidental corruption without an extra platform-specific crypto dependency.
        data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    private static func append(_ value: UInt64, count: Int, to data: inout Data) {
        for shift in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    private static func number(_ data: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        var result: UInt64 = 0
        for shift in 0..<count { result |= UInt64(data[offset + shift]) << (shift * 8) }
        return result
    }
    private static func header(_ data: Data) -> Header? {
        guard data.count >= headerBytes else { return nil }
        let b = [UInt8](data.prefix(headerBytes))
        guard Array(b.prefix(8)) == magic, number(b, 8, 4) == UInt64(metadataVersion) else { return nil }
        let generated = Double(bitPattern: number(b, 12, 8)), length = Int(number(b, 20, 4))
        guard generated.isFinite, generated > 0, length >= 12, length <= RasterPacket.maxBytes else { return nil }
        return Header(generated: generated, length: length, checksum: number(b, 24, 8))
    }
    private static func envelope(_ data: Data, generated: Double) -> Data {
        var output = Data(magic)
        append(UInt64(metadataVersion), count: 4, to: &output)
        append(generated.bitPattern, count: 8, to: &output)
        append(UInt64(data.count), count: 4, to: &output)
        append(checksum(data), count: 8, to: &output)
        output.append(data)
        return output
    }
    private func prepare() {
        lock.lock(); let ready = loaded; lock.unlock()
        if ready { return }
        operation.lock(); defer { operation.unlock() }
        loadLocked()
    }
    /// One directory pass reconciles a missing/corrupt/older index and interrupted atomic writes.
    /// Packet bodies are not read here; a 32-byte envelope supplies their generation time.
    private func loadLocked() {
        guard !loaded else { return }
        var old: [String: Entry] = [:]
        if let size = (try? indexURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 * 1024 * 1024,
           let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data),
           index.version == Self.metadataVersion { old = index.entries }
        var recovered: [String: Entry] = [:], total: Int64 = 0
        let properties: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(properties), options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "bin", let info = try? url.resourceValues(forKeys: properties),
                  info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let size = Int64(info.fileSize ?? 0), modified = info.contentModificationDate?.timeIntervalSince1970 ?? 0
            guard size >= 0, total <= Int64.max - size else { continue }
            var entry = old[relative]
            if entry?.bytes != size || entry?.modified != modified {
                var generated = 0.0
                if let handle = try? FileHandle(forReadingFrom: url) {
                    let prefix = try? handle.read(upToCount: Self.headerBytes)
                    try? handle.close()
                    if let data = prefix, let header = Self.header(data), Int64(header.length + Self.headerBytes) == size {
                        generated = header.generated
                    }
                }
                entry = Entry(bytes: size, generated: generated, accessed: modified, modified: modified, revision: UUID())
            }
            recovered[relative] = entry; total += size
        }
        lock.lock(); entries = recovered; bytes = total; diskScans += 1; loaded = true; lock.unlock()
    }
    /// Called only under operation. A failed checkpoint is recoverable from packet envelopes.
    private func checkpointLocked(force: Bool = false) {
        pendingIndexChanges += 1
        guard force || pendingIndexChanges >= 128 else { return }
        lock.lock(); let snapshot = entries; lock.unlock()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Index(version: Self.metadataVersion, entries: snapshot)).write(to: indexURL, options: .atomic)
            pendingIndexChanges = 0
        } catch { /* Next attempt or startup reconciliation recovers the index. */ }
    }
    private func entry(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }; return entries[key]
    }
    private func removeLocked(_ key: String) throws {
        let url = root.appendingPathComponent(key)
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let ns = error as NSError
            guard ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError else { throw CacheError.io(error.localizedDescription) }
        }
        lock.lock()
        if let removed = entries.removeValue(forKey: key) { bytes -= removed.bytes }
        lock.unlock()
        checkpointLocked()
    }
    private func discardInvalid(_ key: String, revision: UUID) {
        operation.lock(); defer { operation.unlock() }
        guard entry(key)?.revision == revision else { return }
        try? removeLocked(key)
    }
    func lookup(frame: MapGeo.Frame, source: Int, buildings: Bool, node: RouteMapPlan.Node, style: Int = 1) -> Lookup? {
        prepare()
        let name = key(frame: frame, source: source, buildings: buildings, node: node, style: style)
        // A concurrently replaced packet can change between the metadata snapshot and disk read.
        for _ in 0..<2 {
            guard let snapshot = entry(name) else { return nil }
            let url = root.appendingPathComponent(name)
            let stored: Data?
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               (12...(RasterPacket.maxBytes + Self.headerBytes)).contains(size) { stored = try? Data(contentsOf: url) }
            else { stored = nil }
            var packet: Data?, generated = 0.0
            if let stored = stored {
                if let header = Self.header(stored), stored.count == header.length + Self.headerBytes {
                    let payload = Data(stored.dropFirst(Self.headerBytes))
                    if Self.checksum(payload) == header.checksum { packet = payload; generated = header.generated }
                } else if !stored.starts(with: Self.magic) { packet = stored } // Legacy bare packet: usable but stale.
            }
            guard let data = packet, valid(data, frame: frame, node: node, style: style, buildings: buildings) else {
                if entry(name)?.revision != snapshot.revision { continue }
                discardInvalid(name, revision: snapshot.revision)
                return nil
            }
            let time = now().timeIntervalSince1970
            lock.lock()
            if entries[name]?.revision == snapshot.revision { entries[name]?.accessed = time }
            lock.unlock()
            let stale = generated <= 0 || generated > time + 300 || time - generated >= maxAge
            return Lookup(data: data, generatedAt: generated > 0 ? Date(timeIntervalSince1970: generated) : .distantPast, isStale: stale)
        }
        return nil
    }
    func read(frame: MapGeo.Frame, source: Int, buildings: Bool, node: RouteMapPlan.Node, style: Int = 1) -> Data? {
        lookup(frame: frame, source: source, buildings: buildings, node: node, style: style)?.data
    }
    /// Replaces the entire active route protection. A late old-owner close cannot clear a newer route.
    /// Builders/store calls never edit this set, including tasks from a cancelled route.
    func replaceProtection(owner: UUID, frame: MapGeo.Frame, source: Int, nodes: [RouteMapPlan.Node], style: Int, buildings: Bool) {
        let keys = Set(nodes.flatMap { node -> [String] in
            let base = key(frame: frame, source: source, buildings: false, node: node, style: style)
            if MapStylePolicy.usesBuildings(style, enabled: buildings) {
                return [base, key(frame: frame, source: source, buildings: true, node: node, style: style)]
            }
            return [base]
        })
        operation.lock(); defer { operation.unlock() }
        loadLocked()
        lock.lock(); protected = keys; protectionOwner = owner; lock.unlock()
    }
    func clearProtection(owner: UUID) {
        operation.lock(); defer { operation.unlock() }
        lock.lock(); defer { lock.unlock() }
        if protectionOwner == owner { protected = []; protectionOwner = nil }
    }
    /// Check the complete eviction plan before removing anything. Keep active-route packets,
    /// including the old packet being replaced, if the new download/write cannot fit.
    private func makeRoomLocked(for name: String, count: Int64) throws {
        lock.lock()
        let existing = entries[name]?.bytes ?? 0, total = bytes
        lock.unlock()
        let capacityNeed = max(0, total - existing + count - limitBytes)
        let available = availableBytes(root)
        let diskNeed = available.map { max(0, minimumFreeBytes + count - max(0, $0)) } ?? 0
        guard capacityNeed > 0 || diskNeed > 0 else { return }
        lock.lock()
        let candidates = entries.filter { $0.key != name && !protected.contains($0.key) }
            .sorted { $0.value.accessed == $1.value.accessed ? $0.key < $1.key : $0.value.accessed < $1.value.accessed }
        lock.unlock()
        let possible = candidates.reduce(Int64(0)) { $0 + $1.value.bytes }
        guard possible >= capacityNeed else { throw CacheError.capacityProtected }
        guard possible >= diskNeed else { throw CacheError.storageFull }
        let required = max(capacityNeed, diskNeed)
        var freed: Int64 = 0
        for candidate in candidates where freed < required {
            try removeLocked(candidate.key); freed += candidate.value.bytes
        }
    }
    func store(_ data: Data, frame: MapGeo.Frame, source: Int, node: RouteMapPlan.Node, style: Int = 1) throws {
        let buildings = MapStylePolicy.normalize(style) == MapStylePolicy.gta5 ? false : RasterPacket.isBuilding(data)
        guard valid(data, frame: frame, node: node, style: style, buildings: buildings) else { throw MapProcessingError.invalid("离线底图校验失败") }
        let time = now().timeIntervalSince1970
        let stored = Self.envelope(data, generated: time)
        let name = key(frame: frame, source: source, buildings: buildings, node: node, style: style)
        let url = root.appendingPathComponent(name)
        operation.lock(); defer { operation.unlock() }
        loadLocked()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var folder = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try makeRoomLocked(for: name, count: Int64(stored.count))
            try stored.write(to: url, options: .atomic)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
        } catch let error as CacheError { throw error }
        catch {
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) ||
               (ns.domain == NSPOSIXErrorDomain && ns.code == 28) { throw CacheError.storageFull }
            throw CacheError.io(error.localizedDescription)
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? time
        lock.lock()
        let previous = entries[name]?.bytes ?? 0
        entries[name] = Entry(bytes: Int64(stored.count), generated: time, accessed: time, modified: modified, revision: UUID())
        bytes += Int64(stored.count) - previous
        lock.unlock()
        checkpointLocked()
    }
    @discardableResult func clearUnprotected() throws -> Stats {
        operation.lock()
        loadLocked()
        lock.lock(); let names = entries.keys.filter { !protected.contains($0) }; lock.unlock()
        do {
            for name in names { try removeLocked(name) }
            checkpointLocked(force: true)
            operation.unlock()
            return stats()
        } catch { operation.unlock(); throw error }
    }
    func stats() -> Stats {
        prepare()
        lock.lock(); defer { lock.unlock() }
        let protectedEntries = entries.filter { protected.contains($0.key) }
        let generated = entries.values.map(\.generated).filter { $0 > 0 && $0.isFinite }
        return Stats(bytes: bytes, limit: limitBytes,
            protectedBytes: protectedEntries.reduce(Int64(0)) { $0 + $1.value.bytes },
            files: entries.count, protectedFiles: protectedEntries.count,
            oldestGeneratedAt: generated.min().map { Date(timeIntervalSince1970: $0) },
            newestGeneratedAt: generated.max().map { Date(timeIntervalSince1970: $0) }, diskScans: diskScans)
    }
    func sizeText() -> String {
        let value = stats()
        return "离线缓存 \(value.bytes / 1024 / 1024) MB / \(value.limit / 1024 / 1024) MB"
    }
}
