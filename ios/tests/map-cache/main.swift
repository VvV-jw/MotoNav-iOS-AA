import Foundation

var checks = 0
func stage(_ label: String) {
    FileHandle.standardError.write(Data("Map cache stage: \(label) (\(checks) checks)\n".utf8))
}
func fail(_ label: String) -> Never {
    FileHandle.standardError.write(Data("FAIL map-cache after \(checks) checks: \(label)\n".utf8))
    fatalError(label)
}
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fail(label) }; checks += 1
}
final class Clock {
    private let lock = NSLock()
    private var value: Double = 1_800_000_000
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: value) }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}
final class FreeSpace {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000_000
    func available(_ url: URL) -> Int64? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ bytes: Int64) { lock.lock(); value = bytes; lock.unlock() }
}
final class Failures {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-map-cache-\(UUID().uuidString)")
stage("fixture")
defer { try? FileManager.default.removeItem(at: root) }
let frame = MapGeo.Frame(refLat: 31, refLng: 121, id: 77)
let size = RasterPacket.size
let template = MapGeo.encodeRaster(frameId: frame.id, x0: -1200, y0: 1200, w: size, h: size,
    mmPerPx: 2000, idx: [UInt8](repeating: 0, count: size * size))
func node(_ index: Int) -> RouteMapPlan.Node { RouteMapPlan.Node(x: Double(index * 600), y: 0, distance: Double(index * 600)) }
func packet(_ index: Int) -> Data {
    var output = template
    let x = UInt32(bitPattern: Int32(index * 600 - 1200))
    for offset in 0..<4 { output[2 + offset] = UInt8(truncatingIfNeeded: x >> (offset * 8)) }
    return output
}
func url(_ directory: URL, _ index: Int) -> URL {
    directory.appendingPathComponent("aa-styles-v1/amap-sdk-v3/v1-3-base/31.0_121.0/\(index * 600)_0.bin")
}
let packetBytes = Int64(template.count + 32)
let clock = Clock(), disk = FreeSpace()
let ageDirectory = root.appendingPathComponent("age")
let age = RouteMapCache(root: ageDirectory, now: clock.now, availableBytes: disk.available)
try age.store(packet(0), frame: frame, source: 3, node: node(0))
stage("first packet stored")
guard let first = age.lookup(frame: frame, source: 3, buildings: false, node: node(0)) else { fail("Newly stored packet must be readable") }
check(first.data == packet(0) && !first.isStale, "Fresh packet preserves exact round-display bytes")
check(first.generatedAt == clock.now(), "Generated time refers to packet preparation")
check(age.stats().bytes == packetBytes && age.stats().diskScans == 1, "Incremental index counts envelope bytes")
clock.advance(7 * 24 * 3600 - 1)
check(age.lookup(frame: frame, source: 3, buildings: false, node: node(0))?.isStale == false, "Packet remains fresh before seven days")
clock.advance(1)
check(age.lookup(frame: frame, source: 3, buildings: false, node: node(0))?.isStale == true, "Seven-day expiry keeps usable old packet")
check(age.read(frame: frame, source: 3, buildings: false, node: node(0)) == packet(0), "Old read API can continue serving stale map")
try age.store(packet(0), frame: frame, source: 3, node: node(0))
check(age.lookup(frame: frame, source: 3, buildings: false, node: node(0))?.isStale == false, "Successful refresh renews generation time")
check(age.stats().bytes == packetBytes && age.stats().files == 1, "Replacing packet does not leak indexed capacity")
clock.advance(-3600)
check(age.lookup(frame: frame, source: 3, buildings: false, node: node(0))?.isStale == true,
    "Future generation time after a clock correction cannot stay fresh indefinitely")
clock.advance(3600)
check(age.read(frame: frame, source: 1, buildings: false, node: node(0)) == nil, "Provider remains isolated")
check(age.read(frame: frame, source: 3, buildings: false, node: node(0), style: 0) == nil, "Original cannot use material-style packet")

let legacyDirectory = root.appendingPathComponent("legacy")
stage("legacy")
try FileManager.default.createDirectory(at: url(legacyDirectory, 0).deletingLastPathComponent(), withIntermediateDirectories: true)
try packet(0).write(to: url(legacyDirectory, 0), options: .atomic)
let legacy = RouteMapCache(root: legacyDirectory, now: clock.now, availableBytes: disk.available)
let old = legacy.lookup(frame: frame, source: 3, buildings: false, node: node(0))!
check(old.isStale && old.generatedAt == .distantPast && old.data == packet(0), "Legacy bare packet is usable and scheduled for update")
check(legacy.stats().bytes == Int64(template.count), "Legacy bytes recovered without trusting a missing index")

let lruDirectory = root.appendingPathComponent("lru")
stage("capacity")
let lru = RouteMapCache(root: lruDirectory, limitBytes: packetBytes * 3, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
for index in 0..<3 { try lru.store(packet(index), frame: frame, source: 3, node: node(index)); clock.advance(1) }
_ = lru.read(frame: frame, source: 3, buildings: false, node: node(0)); clock.advance(1)
try lru.store(packet(3), frame: frame, source: 3, node: node(3))
check(lru.read(frame: frame, source: 3, buildings: false, node: node(1)) == nil, "Capacity pressure evicts least recently used packet")
check(lru.read(frame: frame, source: 3, buildings: false, node: node(0)) != nil, "Recent read protects packet in LRU order")
check(lru.stats().files == 3 && lru.stats().bytes == packetBytes * 3, "LRU store stays within capacity")
let oldOwner = UUID(), newOwner = UUID()
lru.replaceProtection(owner: oldOwner, frame: frame, source: 3, nodes: [node(0)], style: 1, buildings: false)
lru.replaceProtection(owner: newOwner, frame: frame, source: 3, nodes: [node(2)], style: 1, buildings: false)
lru.clearProtection(owner: oldOwner)
check(lru.stats().protectedFiles == 1 && lru.stats().protectedBytes == packetBytes, "Late old route close cannot remove new route protection")
let unrelated = lruDirectory.appendingPathComponent("keep-notes.txt")
try Data("personal note".utf8).write(to: unrelated)
let cleaned = try lru.clearUnprotected()
check(cleaned.files == 1 && cleaned.protectedFiles == 1 && cleaned.bytes == packetBytes, "Manual cleanup preserves current route")
check(lru.read(frame: frame, source: 3, buildings: false, node: node(2)) != nil, "Current route packet survives manual cleanup")
check(FileManager.default.fileExists(atPath: unrelated.path), "Cleanup does not delete unrelated files")
lru.clearProtection(owner: newOwner)
let released = try lru.clearUnprotected()
check(released.files == 0, "Owner release permits cleanup")

let protectedDirectory = root.appendingPathComponent("protected")
let protectedCache = RouteMapCache(root: protectedDirectory, limitBytes: packetBytes * 2, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
for index in 0..<2 { try protectedCache.store(packet(index), frame: frame, source: 3, node: node(index)) }
protectedCache.replaceProtection(owner: UUID(), frame: frame, source: 3, nodes: [node(0), node(1)], style: 1, buildings: false)
do {
    try protectedCache.store(packet(2), frame: frame, source: 3, node: node(2))
    fail("Protected full cache must stop preparing more packets")
} catch let error as RouteMapCache.CacheError {
    if case .capacityProtected = error { checks += 1 } else { fail("Wrong protected-capacity error") }
    check(error.isStorageBlocked, "Protected capacity pauses automatic retry")
}
check(protectedCache.stats().bytes == packetBytes * 2, "Rejected packet does not count or remove protected bytes")
check(protectedCache.read(frame: frame, source: 3, buildings: false, node: node(0)) != nil, "Protected packet remains after failed capacity reservation")

let diskDirectory = root.appendingPathComponent("disk-full")
stage("disk reserve")
let diskCache = RouteMapCache(root: diskDirectory, minimumFreeBytes: 32 * 1024 * 1024,
    now: clock.now, availableBytes: disk.available)
try diskCache.store(packet(0), frame: frame, source: 3, node: node(0))
let oldTime = diskCache.lookup(frame: frame, source: 3, buildings: false, node: node(0))!.generatedAt
clock.advance(9 * 24 * 3600); disk.set(0)
do {
    try diskCache.store(packet(0), frame: frame, source: 3, node: node(0))
    fail("Disk reserve must stop update")
} catch let error as RouteMapCache.CacheError {
    if case .storageFull = error { checks += 1 } else { fail("Wrong disk-full error") }
    check(error.isStorageBlocked, "Disk-full error pauses retry")
}
let afterFailure = diskCache.lookup(frame: frame, source: 3, buildings: false, node: node(0))!
check(afterFailure.data == packet(0) && afterFailure.generatedAt == oldTime && afterFailure.isStale,
    "Failed replacement leaves exact old map and timestamp intact")
disk.set(1_000_000_000)
try diskCache.store(packet(0), frame: frame, source: 3, node: node(0))
check(diskCache.lookup(frame: frame, source: 3, buildings: false, node: node(0))?.isStale == false,
    "Explicit retry after freeing space succeeds")

let damagedDirectory = root.appendingPathComponent("damaged")
stage("corruption")
let damaged = RouteMapCache(root: damagedDirectory, now: clock.now, availableBytes: disk.available)
try damaged.store(packet(0), frame: frame, source: 3, node: node(0))
var encoded = try Data(contentsOf: url(damagedDirectory, 0))
encoded[48] ^= 1 // Payload can remain structurally valid after an accidental bit change.
try encoded.write(to: url(damagedDirectory, 0), options: .atomic)
check(damaged.read(frame: frame, source: 3, buildings: false, node: node(0)) == nil, "Envelope checksum rejects silent payload corruption")
check(damaged.stats().files == 0 && damaged.stats().bytes == 0, "Corrupt packet is removed from capacity index")
try damaged.store(packet(0), frame: frame, source: 3, node: node(0))
encoded = try Data(contentsOf: url(damagedDirectory, 0)); encoded[8] = 99
try encoded.write(to: url(damagedDirectory, 0), options: .atomic)
check(damaged.read(frame: frame, source: 3, buildings: false, node: node(0)) == nil, "Unsupported envelope version is never mistaken for wire packet")
try damaged.store(packet(0), frame: frame, source: 3, node: node(0))
try Data(encoded.prefix(15)).write(to: url(damagedDirectory, 0), options: .atomic)
check(damaged.read(frame: frame, source: 3, buildings: false, node: node(0)) == nil, "Truncated envelope is rejected")
try damaged.store(packet(0), frame: frame, source: 3, node: node(0))
try FileManager.default.removeItem(at: url(damagedDirectory, 0))
check(damaged.read(frame: frame, source: 3, buildings: false, node: node(0)) == nil && damaged.stats().files == 0,
    "External packet disappearance repairs indexed capacity")

let stressDirectory = root.appendingPathComponent("stress")
stage("2049 files")
let stress = RouteMapCache(root: stressDirectory, limitBytes: packetBytes * 3000, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
for index in 0..<2049 { try stress.store(packet(index), frame: frame, source: 3, node: node(index)) }
let written = stress.stats()
check(written.files == 2049 && written.bytes == packetBytes * 2049, "Thousands of packet writes keep exact incremental accounting")
for _ in 0..<1000 { _ = stress.stats() }
check(stress.stats().diskScans == 1, "Store and stats never repeat initial directory scan")
let restarted = RouteMapCache(root: stressDirectory, limitBytes: packetBytes * 3000, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
check(restarted.stats().bytes == written.bytes && restarted.stats().files == written.files,
    "Restart recovers writes made after last index checkpoint")
for index in [0, 127, 128, 2048] {
    check(restarted.lookup(frame: frame, source: 3, buildings: false, node: node(index))?.data == packet(index), "Restart restores packet identity")
    check(restarted.lookup(frame: frame, source: 3, buildings: false, node: node(index))?.isStale == false, "Restart restores generation time")
}
try Data("corrupt index".utf8).write(to: stressDirectory.appendingPathComponent(".route-map-index-v2.json"))
let recovered = RouteMapCache(root: stressDirectory, limitBytes: packetBytes * 3000, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
check(recovered.stats().bytes == written.bytes && recovered.stats().files == written.files, "Corrupt index rebuilds from atomic map files")
check(recovered.lookup(frame: frame, source: 3, buildings: false, node: node(2048))?.isStale == false,
    "Index damage does not lose packet generation time")

let concurrentDirectory = root.appendingPathComponent("concurrent")
stage("concurrent stores")
let concurrent = RouteMapCache(root: concurrentDirectory, limitBytes: packetBytes * 1000, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
let failures = Failures()
DispatchQueue.concurrentPerform(iterations: 8) { worker in
    for offset in 0..<64 {
        let index = worker * 64 + offset
        do {
            try concurrent.store(packet(index), frame: frame, source: 3, node: node(index))
            if concurrent.lookup(frame: frame, source: 3, buildings: false, node: node(index))?.data != packet(index) { failures.add("packet \(index)") }
            _ = concurrent.stats()
        } catch { failures.add(error.localizedDescription) }
    }
}
check(failures.isEmpty, "Concurrent background reads/writes retain valid packets and capacity")
check(concurrent.stats().files == 512 && concurrent.stats().bytes == packetBytes * 512,
    "Concurrent index increments do not lose updates")
check(concurrent.stats().diskScans == 1, "Concurrent first access initializes index only once")
let concurrentRestart = RouteMapCache(root: concurrentDirectory, limitBytes: packetBytes * 1000, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
check(concurrentRestart.stats().bytes == concurrent.stats().bytes, "Concurrent checkpoint is recoverable on restart")
let replaceDirectory = root.appendingPathComponent("concurrent-replace")
stage("concurrent replacement")
let replacement = RouteMapCache(root: replaceDirectory, limitBytes: packetBytes, minimumFreeBytes: 0,
    now: clock.now, availableBytes: disk.available)
var alternatePacket = packet(0); alternatePacket[16] ^= 1
check(RasterPacket.valid(alternatePacket), "Replacement fixture stays structurally valid")
let variants = [packet(0), alternatePacket]
DispatchQueue.concurrentPerform(iterations: 8) { worker in
    for offset in 0..<64 {
        do {
            try replacement.store(variants[(worker + offset) % 2], frame: frame, source: 3, node: node(0))
            if let result = replacement.read(frame: frame, source: 3, buildings: false, node: node(0)), !variants.contains(result) {
                failures.add("torn replacement")
            }
        } catch { failures.add(error.localizedDescription) }
    }
}
check(failures.isEmpty, "Readers never receive torn packets during repeated atomic replacement")
let lastReplacement = replacement.read(frame: frame, source: 3, buildings: false, node: node(0))
check(lastReplacement != nil && variants.contains(lastReplacement!), "Final concurrent replacement remains readable")
check(replacement.stats().files == 1 && replacement.stats().bytes == packetBytes, "Concurrent replacement does not inflate capacity")
print("Map cache: \(checks) checks passed (2049-file restart, concurrent I/O, expiry, LRU, protection, disk-full and corruption)")
