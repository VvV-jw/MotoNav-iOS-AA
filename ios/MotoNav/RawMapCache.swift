import Foundation

/// Worker-only fixed 256 MiB partition for OFM raw tiles and planet.json.
/// Its index is recovered once, then updated incrementally. SDK caches are separate.
final class RawMapCache {
    static let defaultLimit: Int64 = 256 * 1024 * 1024
    static let defaultReserve: Int64 = 32 * 1024 * 1024
    struct Stats {
        let bytes: Int64, limit: Int64, protectedBytes: Int64
        let files: Int, protectedFiles: Int, diskScans: Int
    }
    struct Lookup { let data: Data, modifiedAt: Date }
    enum CacheError: LocalizedError, MapStorageFailure {
        case storageFull, capacityProtected, io(String)
        var isStorageBlocked: Bool {
            switch self { case .storageFull, .capacityProtected: return true; case .io: return false }
        }
        var errorDescription: String? {
            switch self {
            case .storageFull: return "手机存储空间不足，清理空间后可继续更新地图"
            case .capacityProtected: return "当前地图原始缓存已占满，请稍后重试"
            case .io: return "地图原始缓存读写失败"
            }
        }
    }
    private struct Entry { let bytes: Int64, modified: Date; var accessed: Date }
    final class Lease {
        fileprivate let cache: RawMapCache
        fileprivate var keys: Set<String>?
        fileprivate init(_ cache: RawMapCache, _ keys: Set<String>) { self.cache = cache; self.keys = keys }
        func close() { cache.release(self) }
        deinit { close() }
    }
    private static let sharedLock = NSLock()
    private static var instances: [String: RawMapCache] = [:]
    static let shared = forDirectory(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ofm_tiles_v1", isDirectory: true))
    static func forDirectory(_ root: URL) -> RawMapCache {
        let key = root.standardizedFileURL.path
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let cache = instances[key] { return cache }
        let cache = RawMapCache(root: root); instances[key] = cache; return cache
    }
    private let root: URL, limit: Int64, reserve: Int64
    private let now: () -> Date, availableBytes: (URL) -> Int64?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:], leases: [String: Int] = [:]
    private var bytes: Int64 = 0, scans = 0, loaded = false
    init(root: URL, limitBytes: Int64 = RawMapCache.defaultLimit,
         minimumFreeBytes: Int64 = RawMapCache.defaultReserve,
         now: @escaping () -> Date = Date.init, availableBytes: ((URL) -> Int64?)? = nil) {
        self.root = root.standardizedFileURL; limit = max(0, limitBytes); reserve = max(0, minimumFreeBytes); self.now = now
        self.availableBytes = availableBytes ?? { url in
            var existing = url
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                let parent = existing.deletingLastPathComponent()
                if parent == existing { break }
                existing = parent
            }
            guard let info = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                  let capacity = info.volumeAvailableCapacity else { return nil }
            return Int64(capacity)
        }
    }
    private static func known(_ key: String) -> Bool {
        key == "planet.json" || key.range(of: "^(?:[0-9a-f]{16}|[0-9a-f]{24})/14_[0-9]{1,5}_[0-9]{1,5}\\.pbf$", options: .regularExpression) != nil
    }
    private func url(_ key: String) throws -> URL {
        guard Self.known(key) else { throw CacheError.io("Invalid raw cache key") }
        return root.appendingPathComponent(key).standardizedFileURL
    }
    /// Never follow a link at the root, a revision directory, or a managed filename.
    /// Container aliases above the dedicated root (such as macOS /var) are allowed.
    private func safe(_ target: URL) throws {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target == root || target.path.hasPrefix(prefix) else { throw CacheError.io("Raw cache path escaped") }
        let relative = target == root ? "" : String(target.path.dropFirst(prefix.count))
        var current = root
        for component in [""] + relative.split(separator: "/").map(String.init) {
            if !component.isEmpty { current.appendPathComponent(component) }
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw CacheError.io("Raw cache link rejected")
            }
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let expected = relative.isEmpty ? canonicalRoot : canonicalRoot.appendingPathComponent(relative).standardizedFileURL
        guard target.standardizedFileURL.resolvingSymlinksInPath().path == expected.path else { throw CacheError.io("Raw cache path escaped") }
    }
    private func prepare() {
        guard !loaded else { return }
        let properties: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        if (try? safe(root)) != nil,
           let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(properties), options: [.skipsHiddenFiles]) {
            let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
            let canonicalPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            while let file = enumerator.nextObject() as? URL {
                guard let info = try? file.resourceValues(forKeys: properties) else { continue }
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                // Both sides use the same canonical spelling, including /var container aliases.
                let canonical = file.standardizedFileURL.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(canonicalPrefix) else { enumerator.skipDescendants(); continue }
                let key = String(canonical.dropFirst(canonicalPrefix.count))
                if info.isDirectory == true {
                    if key.range(of: "^(?:[0-9a-f]{16}|[0-9a-f]{24})$", options: .regularExpression) == nil { enumerator.skipDescendants() }
                    continue
                }
                guard Self.known(key), info.isRegularFile == true, let managed = try? url(key),
                      (try? safe(managed)) != nil else { continue }
                let size = Int64(info.fileSize ?? 0), modified = info.contentModificationDate ?? .distantPast
                guard size >= 0, bytes <= Int64.max - size else { continue }
                entries[key] = Entry(bytes: size, modified: modified, accessed: modified); bytes += size
            }
        }
        loaded = true; scans += 1
        for key in candidates(excluding: nil) {
            if bytes <= limit { break }
            _ = try? remove(key)
        }
    }
    func lease(_ keys: Set<String>) throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        for key in keys { _ = try url(key) }
        // Protection is registered before the startup trim.
        for key in keys { leases[key, default: 0] += 1 }
        prepare(); return Lease(self, keys)
    }
    private func release(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard let keys = lease.keys else { return }
        for key in keys {
            let count = leases[key, default: 0]
            if count <= 1 { leases.removeValue(forKey: key) } else { leases[key] = count - 1 }
        }
        lease.keys = nil
    }
    func lookup(_ key: String, maximumBytes: Int, validate: (Data) -> Bool) -> Lookup? {
        lock.lock(); defer { lock.unlock() }; prepare()
        guard let old = entries[key], let target = try? url(key) else { return nil }
        do {
            try safe(target)
            let info = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= maximumBytes else { throw CacheError.io("Invalid raw tile size") }
            let data = try Data(contentsOf: target)
            guard data.count <= maximumBytes, validate(data) else { throw CacheError.io("Invalid raw tile data") }
            let modified = info.contentModificationDate ?? old.modified
            bytes += Int64(data.count) - old.bytes
            entries[key] = Entry(bytes: Int64(data.count), modified: modified, accessed: now())
            return Lookup(data: data, modifiedAt: modified)
        } catch {
            _ = try? remove(key) // safe() prevents removing a replacement symlink's destination.
            return nil
        }
    }
    private func candidates(excluding: String?) -> [String] {
        entries.keys.filter { $0 != excluding && leases[$0] == nil }.sorted {
            let a = entries[$0]!.accessed, b = entries[$1]!.accessed
            return a == b ? $0 < $1 : a < b
        }
    }
    @discardableResult private func remove(_ key: String) throws -> Int64 {
        let target = try url(key); try safe(target)
        if let info = try? target.resourceValues(forKeys: [.isRegularFileKey]), info.isRegularFile != true { throw CacheError.io("Raw cache file rejected") }
        do { try FileManager.default.removeItem(at: target) }
        catch {
            let ns = error as NSError
            guard ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError else { throw error }
        }
        let old = entries.removeValue(forKey: key)?.bytes ?? 0; bytes -= old; return old
    }
    func store(_ key: String, data: Data, maximumBytes: Int, validate: (Data) -> Bool) throws {
        lock.lock(); defer { lock.unlock() }; prepare()
        let target = try url(key); try safe(target)
        // Empty protobuf ocean tiles are valid when their format validator accepts them.
        guard data.count <= maximumBytes, validate(data) else { throw CacheError.io("Invalid raw map data") }
        let oldSize = entries[key]?.bytes ?? 0
        let size = Int64(data.count), capacityNeed = max(0, bytes - oldSize + size - limit)
        // If capacity cannot be queried, do not risk replacing a valid old file.
        let free = max(0, availableBytes(root) ?? 0), storageNeed = max(0, reserve + size - free)
        var reclaim: Int64 = 0, plan: [String] = []
        for key in candidates(excluding: key) {
            if reclaim >= capacityNeed && reclaim >= storageNeed { break }
            plan.append(key); reclaim += entries[key]!.bytes
        }
        guard reclaim >= capacityNeed else { throw CacheError.capacityProtected }
        guard reclaim >= storageNeed else { throw CacheError.storageFull }
        // The complete plan is checked before deleting anything. The old target is excluded.
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try safe(target)
        for key in plan { try remove(key) }
        // Foundation .atomic stages a sibling and atomically replaces the destination.
        try data.write(to: target, options: .atomic)
        let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now()
        entries[key] = Entry(bytes: size, modified: modified, accessed: now()); bytes = bytes - oldSize + size
    }
    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }; prepare()
        return snapshot()
    }
    private func snapshot() -> Stats {
        let protected = entries.filter { leases[$0.key] != nil }
        return Stats(bytes: bytes, limit: limit, protectedBytes: protected.values.reduce(0) { $0 + $1.bytes },
                     files: entries.count, protectedFiles: protected.count, diskScans: scans)
    }
    @discardableResult func clearUnprotected() -> Int {
        lock.lock(); defer { lock.unlock() }; prepare()
        var count = 0
        for key in candidates(excluding: nil) { if (try? remove(key)) != nil { count += 1 } }
        return count
    }
    /// Interactive maintenance must surface failed/partial deletion to its caller.
    func clearUnprotectedStrict() throws -> Stats {
        lock.lock(); defer { lock.unlock() }; prepare()
        for key in candidates(excluding: nil) { try remove(key) }
        return snapshot()
    }
}
