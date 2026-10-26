import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("Raw cache check \(checks + 1): \(label)") }; checks += 1
}
final class Clock {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func tick() { lock.lock(); value.addTimeInterval(1); lock.unlock() }
}
final class Disk {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000_000
    func available(_ url: URL) -> Int64? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ bytes: Int64) { lock.lock(); value = bytes; lock.unlock() }
}
final class Failures {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ error: String) { lock.lock(); values.append(error); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }
}
let manager = FileManager.default, clock = Clock(), disk = Disk()
let root = manager.temporaryDirectory.appendingPathComponent("motonav-raw-cache-\(UUID().uuidString)")
defer { try? manager.removeItem(at: root) }
func key(_ n: Int) -> String { "0123456789abcdef/14_\(n)_1.pbf" }
func data(_ n: Int) -> Data { var bytes = Data(repeating: UInt8(truncatingIfNeeded: n), count: 64); bytes[0] = 7; return bytes }
let valid: (Data) -> Bool = { $0.count == 64 && $0.first == 7 }
func cache(_ name: String, _ limit: Int64) -> RawMapCache {
    RawMapCache(root: root.appendingPathComponent(name), limitBytes: limit, minimumFreeBytes: 128,
                now: clock.now, availableBytes: disk.available)
}
func put(_ cache: RawMapCache, _ key: String, _ n: Int) throws { try cache.store(key, data: data(n), maximumBytes: 64, validate: valid) }
func pressure(_ protectedCapacity: Bool, _ work: () throws -> Void) {
    do { try work(); fatalError("Expected raw cache storage failure") }
    catch RawMapCache.CacheError.capacityProtected { check(protectedCapacity, "typed capacity pressure") }
    catch RawMapCache.CacheError.storageFull { check(!protectedCapacity, "typed disk pressure") }
    catch { fatalError("Unexpected raw pressure error: \(error)") }
}

let lru = cache("lru", 128)
try put(lru, key(1), 1); clock.tick(); try put(lru, key(2), 2); clock.tick()
check(lru.lookup(key(1), maximumBytes: 64, validate: valid)?.data == data(1), "raw read succeeds")
clock.tick(); try put(lru, key(3), 3)
check(lru.lookup(key(2), maximumBytes: 64, validate: valid) == nil, "read access determines LRU")
check(lru.stats().bytes == 128 && lru.stats().files == 2, "raw cap accounting")
for _ in 0..<400 { _ = lru.stats(); _ = lru.lookup(key(1), maximumBytes: 64, validate: valid) }
check(lru.stats().diskScans == 1, "reads and stats never re-enumerate")

let emptyRoot = root.appendingPathComponent("empty")
let empty = cache("empty", 256), emptyTile: (Data) -> Bool = { $0.isEmpty }
try empty.store(key(0), data: Data(), maximumBytes: 64, validate: emptyTile)
check(empty.lookup(key(0), maximumBytes: 64, validate: emptyTile)?.data == Data(), "validator-approved empty ocean tile round trips")
check(empty.stats().bytes == 0 && empty.stats().files == 1, "zero-byte raw tile counts as one managed file")
let emptyRestart = RawMapCache(root: emptyRoot, limitBytes: 256, minimumFreeBytes: 128, availableBytes: disk.available)
check(emptyRestart.lookup(key(0), maximumBytes: 64, validate: emptyTile)?.data == Data() &&
      emptyRestart.stats().bytes == 0 && emptyRestart.stats().files == 1, "cold startup recovers zero-byte ocean tile")
do { try empty.store("planet.json", data: Data(), maximumBytes: 64, validate: valid); fatalError("Invalid empty manifest accepted") }
catch { check(empty.stats().files == 1, "format validator still rejects invalid empty data") }

let leased = cache("leased", 192)
let active = try leased.lease(["planet.json", key(1)])
try put(leased, "planet.json", 1); try put(leased, key(1), 2); try put(leased, key(2), 3)
check(leased.stats().protectedBytes == 128 && leased.stats().protectedFiles == 2, "manifest and tile lease accounting")
check(leased.clearUnprotected() == 1, "manual clear skips active raw build")
check(leased.lookup("planet.json", maximumBytes: 64, validate: valid) != nil && leased.lookup(key(1), maximumBytes: 64, validate: valid) != nil,
      "manifest and tiles survive manual clear")
let nested = try leased.lease([key(1)]); nested.close(); nested.close()
check(leased.stats().protectedFiles == 2, "nested idempotent release preserves outer protection")
active.close()
check(leased.clearUnprotected() == 2 && leased.stats().bytes == 0, "ended build becomes clearable")

let blocked = cache("blocked", 128)
try put(blocked, key(1), 1); try put(blocked, key(2), 2)
let protected = try blocked.lease([key(1), key(2)])
pressure(true) { try put(blocked, key(3), 3) }
check(blocked.stats().bytes == 128, "failed capacity plan keeps all previous files")
protected.close(); disk.set(0)
pressure(false) { try put(blocked, key(1), 9) }
check(blocked.lookup(key(1), maximumBytes: 64, validate: valid)?.data == data(1), "disk full preserves previous target")
check(blocked.lookup(key(2), maximumBytes: 64, validate: valid) != nil, "failed storage plan does not partially evict")
disk.set(1_000_000_000)
do { try blocked.store(key(1), data: Data(repeating: 0, count: 65), maximumBytes: 64, validate: valid); fatalError("Oversize accepted") }
catch { check(blocked.lookup(key(1), maximumBytes: 64, validate: valid)?.data == data(1), "invalid replacement preserves old file") }

let recoverRoot = root.appendingPathComponent("recover")
try manager.createDirectory(at: recoverRoot.appendingPathComponent("0123456789abcdef"), withIntermediateDirectories: true)
try manager.createDirectory(at: recoverRoot.appendingPathComponent("0123456789abcdef01234567"), withIntermediateDirectories: true)
try data(1).write(to: recoverRoot.appendingPathComponent(key(1)))
try data(2).write(to: recoverRoot.appendingPathComponent("0123456789abcdef01234567/14_2_1.pbf"))
try data(3).write(to: recoverRoot.appendingPathComponent("planet.json"))
try data(4).write(to: recoverRoot.appendingPathComponent("keep.txt"))
let recovered = cache("recover", 128)
check(recovered.stats().bytes == 128 && recovered.stats().files == 2, "startup trims all revisions and manifest")
recovered.clearUnprotected()
check(manager.fileExists(atPath: recoverRoot.appendingPathComponent("keep.txt").path), "clear only removes known raw files")

// Recover real on-disk files before any cache instance exists, then exercise a
// parent-directory alias like the macOS /var -> /private/var container spelling.
let coldRoot = root.appendingPathComponent("physical/cold")
try manager.createDirectory(at: coldRoot.appendingPathComponent("0123456789abcdef"), withIntermediateDirectories: true)
try data(5).write(to: coldRoot.appendingPathComponent(key(5)))
try data(6).write(to: coldRoot.appendingPathComponent("planet.json"))
let cold = RawMapCache(root: coldRoot, limitBytes: 256, minimumFreeBytes: 128, availableBytes: disk.available)
check(cold.lookup(key(5), maximumBytes: 64, validate: valid)?.data == data(5) &&
      cold.lookup("planet.json", maximumBytes: 64, validate: valid)?.data == data(6), "cold startup recovers existing raw keys and manifest")
check(cold.stats().bytes == 128 && cold.stats().diskScans == 1, "cold startup scans exactly once")
let alias = root.appendingPathComponent("parent-alias")
try manager.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("physical"))
let aliased = RawMapCache(root: alias.appendingPathComponent("cold"), limitBytes: 256, minimumFreeBytes: 128, availableBytes: disk.available)
check(aliased.lookup(key(5), maximumBytes: 64, validate: valid)?.data == data(5) &&
      aliased.lookup("planet.json", maximumBytes: 64, validate: valid)?.data == data(6), "cold startup uses canonical keys through a parent alias")
check(aliased.stats().bytes == 128 && aliased.stats().diskScans == 1, "parent alias preserves incremental index accounting")

let damaged = cache("damaged", 256)
try put(damaged, key(1), 1)
try Data([1, 2]).write(to: root.appendingPathComponent("damaged").appendingPathComponent(key(1)))
check(damaged.lookup(key(1), maximumBytes: 64, validate: valid) == nil && damaged.stats().bytes == 0, "corrupt file removed from index")
let strict = cache("strict", 256), strictRoot = root.appendingPathComponent("strict")
try put(strict, key(1), 1); clock.tick(); try put(strict, key(2), 2)
let changed = strictRoot.appendingPathComponent(key(2))
try manager.removeItem(at: changed); try manager.createDirectory(at: changed, withIntermediateDirectories: true)
do { _ = try strict.clearUnprotectedStrict(); fatalError("Failed strict raw clear was reported successful") }
catch { check(!manager.fileExists(atPath: strictRoot.appendingPathComponent(key(1)).path) && strict.stats().files == 1,
              "strict clear propagates failure and accounts completed deletions") }
try manager.removeItem(at: changed)
let strictAfterRetry = try strict.clearUnprotectedStrict()
check(strictAfterRetry.bytes == 0, "strict retry returns current statistics")
for unsafe in ["../planet.json", "/planet.json", "0123456789abcdef/../planet.json", "abc/14_1_1.pbf", "planet.json/evil"] {
    do { try put(damaged, unsafe, 1); fatalError("Unsafe raw key accepted") }
    catch { checks += 1 }
}
let outside = root.appendingPathComponent("outside"), links = root.appendingPathComponent("links")
try manager.createDirectory(at: outside, withIntermediateDirectories: true)
try manager.createDirectory(at: links, withIntermediateDirectories: true)
try data(9).write(to: outside.appendingPathComponent("14_1_1.pbf"))
try manager.createSymbolicLink(at: links.appendingPathComponent("0123456789abcdef"), withDestinationURL: outside)
let linked = cache("links", 128)
check(linked.stats().bytes == 0, "scan refuses symlink revision")
do { try put(linked, key(1), 1); fatalError("Symlink write accepted") }
catch { checks += 1 }
linked.clearUnprotected()
let outsideData = try Data(contentsOf: outside.appendingPathComponent("14_1_1.pbf"))
check(outsideData == data(9), "clear never deletes symlink destination")
let rootLink = root.appendingPathComponent("root-link")
try manager.createSymbolicLink(at: rootLink, withDestinationURL: outside)
let rootLinked = RawMapCache(root: rootLink, limitBytes: 128, minimumFreeBytes: 0, availableBytes: disk.available)
do { try put(rootLinked, "planet.json", 1); fatalError("Symlink root write accepted") }
catch { checks += 1 }
check(!manager.fileExists(atPath: outside.appendingPathComponent("planet.json").path), "linked root destination untouched")

let concurrent = cache("concurrent", 1024), failures = Failures()
let queue = OperationQueue(); queue.maxConcurrentOperationCount = 8
for worker in 0..<6 {
    queue.addOperation {
        do {
            for n in 0..<100 {
                let tile = key(worker * 100 + n), protection = try concurrent.lease([key(worker * 100 + n)])
                defer { protection.close() }
                try put(concurrent, tile, n)
                if concurrent.lookup(tile, maximumBytes: 64, validate: valid)?.data != data(n) { failures.append("Concurrent lease lost tile") }
            }
        } catch { failures.append(error.localizedDescription) }
    }
}
queue.addOperation { for _ in 0..<350 { concurrent.clearUnprotected(); _ = concurrent.stats() } }
queue.waitUntilAllOperationsAreFinished()
check(failures.isEmpty && concurrent.stats().bytes <= 1024 && concurrent.stats().diskScans == 1,
      "600 concurrent stores and manual clears remain bounded with one scan")
concurrent.clearUnprotected(); check(concurrent.stats().bytes == 0, "stress clear completes")
check(RawMapCache.forDirectory(root.appendingPathComponent("shared")) === RawMapCache.forDirectory(root.appendingPathComponent("shared")), "per-directory shared instance")
check(RawMapCache.defaultLimit == 256 * 1024 * 1024, "fixed 256 MiB raw partition")
print("RawMapCache: \(checks) checks passed (600 concurrent stores)")
