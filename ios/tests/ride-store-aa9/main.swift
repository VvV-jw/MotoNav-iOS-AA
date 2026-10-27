import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError("RideStoreAA9 \(checks + 1): \(message)") }; checks += 1
}
func wait(_ message: String, until ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(ready(), message)
}
final class Locked<T> {
    private let lock = NSLock(); private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: T) { lock.lock(); value = next; lock.unlock() }
    func edit(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
}
let base = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-ride-aa9-\(UUID())")
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }
let date = Date(timeIntervalSince1970: 1_800_000_000)
func fix(_ i: Int, segment: Bool = false, offset: TimeInterval = 0) -> RideFix {
    RideFix(lat: 31 + Double(i) * 0.00004, lng: 121, time: date.addingTimeInterval(Double(i) + offset), speed: 4.4, startsSegment: segment)
}
func page(_ store: RideStore, before: RideStore.Cursor? = nil) throws -> RideStore.Page {
    let result = Locked<Result<RideStore.Page, RideStoreFailure>?>(nil)
    check(store.page(before: before) { result.set($0) }, "history request enqueued")
    store.flushForTests()
    return try result.get()!.get()
}
func exported(_ store: RideStore, _ id: UUID, directory: URL? = nil) throws -> URL {
    let result = Locked<Result<URL, RideStoreFailure>?>(nil)
    check(store.export(id, to: directory ?? base.appendingPathComponent("exports")) { result.set($0) }, "export enqueued")
    store.flushForTests(); return try result.get()!.get()
}
func finish(_ store: RideStore, _ id: UUID, seconds: Double = 100_000) {
    check(store.finish(id, at: date.addingTimeInterval(seconds)), "finish enqueued"); store.flushForTests()
}
final class GPXCheck: NSObject, XMLParserDelegate {
    var points = 0, segments = 0, times = 0
    var firstLat: String?, lastLat: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "trkseg" { segments += 1 }
        if name == "trkpt" { points += 1; firstLat = firstLat ?? attributes["lat"]; lastLat = attributes["lat"] }
        if name == "time" { times += 1 }
    }
}
func parse(_ url: URL) -> GPXCheck {
    let observer = GPXCheck(), parser = XMLParser(contentsOf: url)!
    parser.delegate = observer
    check(parser.parse(), "complete GPX is well-formed XML")
    return observer
}

// The same constant-size policy used by the live CLLocation adapter: accuracy,
// sample order, displacement and gaps are validated without CoreLocation/SDK.
var policy = RideRecordingPolicy()
check(policy.accept(fix(0), accuracy: 5, now: date)?.startsSegment == true, "first point starts segment")
check(policy.accept(fix(0), accuracy: 5, now: date) == nil, "duplicate fix rejected")
check(policy.accept(fix(1), accuracy: 5, now: date.addingTimeInterval(1))?.startsSegment == false, "normal movement connected")
check(policy.accept(fix(2), accuracy: 100, now: date.addingTimeInterval(2)) == nil, "inaccurate fix rejected")
check(policy.accept(fix(3), accuracy: 5, now: date.addingTimeInterval(3))?.startsSegment == true, "accuracy gap not bridged")
check(policy.accept(fix(35), accuracy: 5, now: date.addingTimeInterval(35))?.startsSegment == true, "long GPS interruption not bridged")
let jump = RideFix(lat: 40, lng: 121, time: date.addingTimeInterval(36), speed: 5)
check(policy.accept(jump, accuracy: 5, now: jump.time) == nil, "single implausible jump rejected")
let relocated = RideFix(lat: 40.0001, lng: 121, time: date.addingTimeInterval(37), speed: 5)
check(policy.accept(relocated, accuracy: 5, now: relocated.time)?.startsSegment == true, "reacquired position starts new segment")
check(policy.accept(fix(1), accuracy: 5, now: date.addingTimeInterval(50)) == nil, "old fix rejected")
check(RideFix(lat: .nan, lng: 121, time: date, speed: 1).isValid == false, "nonfinite coordinate rejected")

// A 60,000-point real append journal is exported completely, not downsampled or
// represented by an in-memory fake. It contains an actual GPS gap at halfway.
let workerChecks = Locked(0)
let store = RideStore(root: base.appendingPathComponent("long"), beforeWrite: { _ in
    if Thread.isMainThread { fatalError("Ride filesystem write reached main") }; workerChecks.edit { $0 += 1 }
})
let long = RideSummary(started: date, mode: "长途 & <测试>")
check(store.begin(long), "long ride begin accepted"); store.flushForTests()
let longCount = 60_000
for i in 0..<longCount {
    check(store.append(fix(i, segment: i == 0 || i == longCount / 2, offset: i >= longCount / 2 ? 60 : 0), to: long.id), "long point accepted")
    if i % 400 == 399 { store.flushForTests() }
}
store.flushForTests()
let metadataBefore = try Data(contentsOf: store.root.appendingPathComponent(long.id.uuidString + ".ride/metadata.json"))
check(metadataBefore.count < 2048, "live metadata stays tiny while journal grows")
let metadataJSON = try JSONSerialization.jsonObject(with: metadataBefore) as! [String: Any]
check(metadataJSON["pointCount"] as? Int == 0, "metadata is not rewritten at every accepted fix")
finish(store, long.id)
let listed = try page(store)
check(listed.rides.count == 1 && listed.rides[0].pointCount == longCount, "history contains complete point count without point arrays")
check(listed.rides[0].segments == 2, "saved GPS interruption remains separate segment")
let longGPX = try exported(store, long.id), parsedLong = parse(longGPX)
check(parsedLong.points == longCount && parsedLong.times == longCount && parsedLong.segments == 2, "GPX preserves every point time and segment")
check(parsedLong.firstLat == "31.0" && parsedLong.lastLat == String(31 + Double(longCount - 1) * 0.00004), "GPX includes first and final recorded coordinates")
check(store.maximumReadBuffer <= 64 * 1024 + 1024, "GPX input streaming buffer bounded independently of track length")
check(store.maximumPendingOperations <= 401 && workerChecks.get() > longCount, "point backlog bounded and actual operations ran on worker")

// FIFO isolation: stop/open/delete and stale points use their own immutable UUID;
// neither a delayed fix nor an old finish can touch the replacement ride.
let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), once = Locked(true)
let racing = RideStore(root: base.appendingPathComponent("fifo"), beforeWrite: { kind in
    if kind == "point", once.get() { once.set(false); entered.signal(); _ = release.wait(timeout: .now() + 8) }
})
let a = RideSummary(started: date, mode: "A"), b = RideSummary(started: date.addingTimeInterval(10), mode: "B")
check(racing.begin(a), "A begin"); racing.flushForTests()
check(racing.append(fix(0, segment: true), to: a.id), "A first point")
check(entered.wait(timeout: .now() + 8) == .success, "point disk boundary paused")
check(racing.append(fix(1), to: a.id), "A queued second")
check(racing.finish(a.id, at: date.addingTimeInterval(2)), "A finish queued")
check(racing.begin(b), "B start queued")
check(racing.append(fix(2), to: a.id), "stale A point queued for rejection")
check(racing.append(fix(10, segment: true), to: b.id), "B point queued")
var removed = false
check(racing.remove(a.id) { if case .success = $0 { removed = true } }, "A deletion queued")
check(racing.finish(a.id, at: date.addingTimeInterval(20)), "stale A finish queued")
check(racing.finish(b.id, at: date.addingTimeInterval(21)), "B finish queued")
release.signal(); racing.flushForTests()
let racePage = try page(racing)
check(removed && racePage.rides.map(\.id) == [b.id] && racePage.rides[0].pointCount == 1, "FIFO deletion and stale writes leave only B")
let bExport = parse(try exported(racing, b.id))
check(bExport.points == 1 && bExport.firstLat == String(fix(10).lat), "replacement export has no previous ride coordinates")

// Backpressure is explicit and cannot retain an unbounded trail in memory. The
// reserve keeps finish/control requests admissible while the point queue is full.
let slowEntered = DispatchSemaphore(value: 0), slowRelease = DispatchSemaphore(value: 0), slowFirst = Locked(true)
var smallLimits = RideStore.Limits(); smallLimits.queuedOperations = 8; smallLimits.reservedControls = 4
let bounded = RideStore(root: base.appendingPathComponent("bounded"), limits: smallLimits, beforeWrite: { kind in
    if kind == "point", slowFirst.get() { slowFirst.set(false); slowEntered.signal(); _ = slowRelease.wait(timeout: .now() + 8) }
})
var busyNotices = 0
bounded.observeFailures { _, failure in if failure == .busy { busyNotices += 1 } }
let crowded = RideSummary(started: date, mode: "bounded")
check(bounded.begin(crowded), "bounded begin"); bounded.flushForTests()
check(bounded.append(fix(0, segment: true), to: crowded.id), "paused point accepted")
check(slowEntered.wait(timeout: .now() + 8) == .success, "slow store boundary entered")
for i in 1...8 { check(bounded.append(fix(i), to: crowded.id), "bounded pending point") }
for i in 9..<200 { check(!bounded.append(fix(i), to: crowded.id), "overflow point rejected explicitly") }
check(bounded.pendingOperationCount == 8, "pending queue does not grow during stalled disk")
check(bounded.finish(crowded.id, at: date.addingTimeInterval(200)), "control reserve permits finish")
slowRelease.signal(); bounded.flushForTests()
wait("overflow notice delivered on main") { busyNotices > 0 }
check(bounded.maximumPendingOperations <= 12, "point/control queue remains bounded")
let boundedPage = try page(bounded)
check(boundedPage.rides[0].pointCount == 9, "only accepted points saved, no invented placeholders")

// Process crash: the header is intentionally unfinished, a final partial write
// is truncated, and all preceding complete points recover into one history item.
let crashRoot = base.appendingPathComponent("crash"), crashed = RideStore(root: crashRoot)
let unfinished = RideSummary(started: date, mode: "interrupted")
check(crashed.begin(unfinished), "crash begin"); crashed.flushForTests()
for i in 0..<20 { check(crashed.append(fix(i, segment: i == 0), to: unfinished.id), "crash prefix point") }
crashed.flushForTests(); crashed.closeForTests()
let crashJournal = crashRoot.appendingPathComponent(unfinished.id.uuidString + ".ride/points.ndjson")
let originalBytes = try Data(contentsOf: crashJournal)
let partial = try FileHandle(forWritingTo: crashJournal); try partial.seekToEnd(); try partial.write(contentsOf: Data("{\"lat\":31".utf8)); try partial.close()
let recovered = RideStore(root: crashRoot), recoveredPage = try page(recovered)
check(recoveredPage.rides.count == 1 && recoveredPage.rides[0].pointCount == 20 && recoveredPage.rides[0].recovered, "crash recovery retains complete prefix")
check(tryData(crashJournal) == originalBytes, "only incomplete crash tail removed")
let recoveredGPX = parse(try exported(recovered, unfinished.id))
check(recoveredGPX.points == 20, "recovered GPX remains complete for committed points")

// Complete malformed lines are not crash-tail guesses: original bytes remain,
// the history item stays visible with a warning, and no partial GPX is published.
let damageRoot = base.appendingPathComponent("damage"), damage = RideStore(root: damageRoot)
let damaged = RideSummary(started: date, mode: "damaged")
check(damage.begin(damaged), "damage begin"); damage.flushForTests()
check(damage.append(fix(0, segment: true), to: damaged.id), "damage valid prefix"); damage.flushForTests(); damage.closeForTests()
let damageFile = damageRoot.appendingPathComponent(damaged.id.uuidString + ".ride/points.ndjson")
let damageHandle = try FileHandle(forWritingTo: damageFile); try damageHandle.seekToEnd(); try damageHandle.write(contentsOf: Data("{broken}\n".utf8)); try damageHandle.close()
let damagedBytes = try Data(contentsOf: damageFile), damageRestart = RideStore(root: damageRoot)
let warningPage = try page(damageRestart)
check(warningPage.rides.count == 1 && warningPage.rides[0].readProblem, "damaged history remains visible without pretending complete")
check(tryData(damageFile) == damagedBytes, "complete corrupt record never blindly removed")
do { _ = try exported(damageRestart, damaged.id); fatalError("corrupt GPX unexpectedly succeeded") }
catch { check(error as? RideStoreFailure == .corrupt, "corrupt export reports explicit error") }
check(!FileManager.default.fileExists(atPath: base.appendingPathComponent("exports/MotoNav-\(damaged.id.uuidString).gpx").path), "failed export has no misleading final file")

// Legacy migration uses the exact old app JSON shape and default date encoding.
// Valid source bytes are retained even after a complete journal is published.
struct LegacyFix: Codable { let lat: Double, lng: Double, time: Date, speed: Double }
struct LegacyRide: Codable { let id: UUID, started: Date, ended: Date?, mode: String, fixes: [LegacyFix], meters: Double }
let legacyRoot = base.appendingPathComponent("legacy")
try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
let legacyID = UUID(), legacyURL = legacyRoot.appendingPathComponent(legacyID.uuidString + ".json")
let oldPoints = (0..<12).map { i in LegacyFix(lat: fix(i).lat, lng: fix(i).lng, time: date.addingTimeInterval(Double(i) + (i >= 6 ? 60 : 0)), speed: 4) }
let old = LegacyRide(id: legacyID, started: date, ended: nil, mode: "旧版", fixes: oldPoints, meters: 999)
let legacyBytes = try JSONEncoder().encode(old); try legacyBytes.write(to: legacyURL)
let migrationStore = RideStore(root: legacyRoot)
_ = try page(migrationStore)
migrationStore.flushMigrationForTests()
var migratedPage: RideStore.Page?
for _ in 0..<8 { migrationStore.flushForTests(); let candidate = try page(migrationStore); if !candidate.isMigrating { migratedPage = candidate; break } }
check(migratedPage?.rides.count == 1 && migratedPage?.rides.first?.pointCount == 12, "legacy migration publishes complete old track asynchronously")
check(migratedPage?.rides.first?.segments == 2 && migratedPage?.rides.first?.recovered == true, "legacy gap and unfinished session recovered")
check(tryData(legacyURL) == legacyBytes, "legacy original remains byte-for-byte compatibility backup")
let migratedGPX = parse(try exported(migrationStore, legacyID))
check(migratedGPX.points == 12 && migratedGPX.segments == 2, "legacy GPX contains full point sequence and gap")
var deletedLegacy = false
check(migrationStore.remove(legacyID) { if case .success = $0 { deletedLegacy = true } }, "legacy deletion enqueued"); migrationStore.flushForTests()
check(deletedLegacy && !FileManager.default.fileExists(atPath: legacyURL.path), "explicit deletion removes legacy backup as well")
let afterDelete = RideStore(root: legacyRoot)
_ = try page(afterDelete); afterDelete.flushForTests()
let deletedPage = try page(afterDelete)
check(deletedPage.rides.isEmpty, "legacy deletion cannot resurrect after restart")

let oversizedRoot = base.appendingPathComponent("legacy-oversized")
try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
let oversizedURL = oversizedRoot.appendingPathComponent(legacyID.uuidString + ".json")
try legacyBytes.write(to: oversizedURL)
var legacyLimits = RideStore.Limits(); legacyLimits.legacyBytes = 16
let oversized = RideStore(root: oversizedRoot, limits: legacyLimits)
var sizeNotice = false
oversized.observeFailures { _, failure in if failure == .legacyTooLarge { sizeNotice = true } }
_ = try page(oversized); oversized.flushForTests()
oversized.flushMigrationForTests()
wait("legacy size limit explicitly reported") { sizeNotice }
check(tryData(oversizedURL) == legacyBytes, "oversized legacy source preserved")
let retainedPage = try page(oversized)
check(retainedPage.retainedLegacy == 1 && retainedPage.legacyFailures.contains(.legacyTooLarge), "legacy limit remains explicit in history after transient error callback")
let invalidRoot = base.appendingPathComponent("legacy-invalid")
try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
let invalidURL = invalidRoot.appendingPathComponent(UUID().uuidString + ".json")
try Data("{invalid".utf8).write(to: invalidURL)
let invalidLegacy = RideStore(root: invalidRoot); var invalidNotice = false
invalidLegacy.observeFailures { _, failure in if failure == .legacyInvalid { invalidNotice = true } }
_ = try page(invalidLegacy); invalidLegacy.flushForTests()
invalidLegacy.flushMigrationForTests()
wait("corrupt legacy explicitly reported") { invalidNotice }
check(FileManager.default.fileExists(atPath: invalidURL.path), "corrupt legacy source not deleted")

// Denied storage, mid-stream export failure, and interrupted migration leave
// prior data intact and return fixed, actionable errors instead of blocking nav.
let blockedRoot = base.appendingPathComponent("blocked")
try Data([1]).write(to: blockedRoot)
let blocked = RideStore(root: blockedRoot)
let beginResult = Locked<Result<RideSummary, RideStoreFailure>?>(nil)
check(blocked.begin(RideSummary(started: date, mode: "blocked")) { beginResult.set($0) }, "storage failure job accepted"); blocked.flushForTests()
if case .failure(let failure)? = beginResult.get() { check(failure == .storage, "directory denial surfaces fixed storage failure") } else { fatalError("denied store started") }
let exportFailure = RideStore(root: store.root, beforeWrite: { kind in if kind == "export" { throw RideStoreFailure.storage } })
let exportDirectory = base.appendingPathComponent("failed-export")
do { _ = try exported(exportFailure, long.id, directory: exportDirectory); fatalError("injected export failure accepted") }
catch { check(error as? RideStoreFailure == .storage, "stream export failure surfaced") }
let failedExports = (try? FileManager.default.contentsOfDirectory(atPath: exportDirectory.path)) ?? []
check(failedExports.isEmpty, "failed stream export removes its pending file only")
let retryLegacyRoot = base.appendingPathComponent("legacy-retry")
try FileManager.default.createDirectory(at: retryLegacyRoot, withIntermediateDirectories: true)
let retryLegacyURL = retryLegacyRoot.appendingPathComponent(legacyID.uuidString + ".json"); try legacyBytes.write(to: retryLegacyURL)
let failedMigration = RideStore(root: retryLegacyRoot, beforeWrite: { kind in if kind == "migration" { throw RideStoreFailure.storage } })
_ = try page(failedMigration); failedMigration.flushForTests()
failedMigration.flushMigrationForTests()
check(tryData(retryLegacyURL) == legacyBytes && !FileManager.default.fileExists(atPath: retryLegacyRoot.appendingPathComponent(legacyID.uuidString + ".ride").path), "failed migration never publishes partial modern ride or removes legacy")
let retryMigration = RideStore(root: retryLegacyRoot)
_ = try page(retryMigration); retryMigration.flushForTests(); retryMigration.flushForTests()
retryMigration.flushMigrationForTests()
let retried = try page(retryMigration)
check(retried.rides.first?.pointCount == 12, "later launch can retry intact legacy conversion")

// Legacy conversion yields after 512 points: a fresh trip can begin and save
// before a 2,048-point old track completes. Deletion during conversion wins too.
let batchLegacy = LegacyRide(id: UUID(), started: date, ended: date.addingTimeInterval(3000), mode: "large-old",
    fixes: (0..<2048).map { LegacyFix(lat: fix($0).lat, lng: 121, time: fix($0).time, speed: 4) }, meters: 0)
for deleteDuringMigration in [false, true] {
    let batchRoot = base.appendingPathComponent("migration-priority-\(deleteDuringMigration)")
    try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
    let legacyFile = batchRoot.appendingPathComponent(batchLegacy.id.uuidString + ".json")
    try JSONEncoder().encode(batchLegacy).write(to: legacyFile)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), first = Locked(true), writes = Locked(0)
    let batched = RideStore(root: batchRoot, beforeWrite: { kind in
        if kind == "migration" {
            writes.edit { $0 += 1 }
            if first.get() { first.set(false); entered.signal(); _ = release.wait(timeout: .now() + 8) }
        }
    })
    check(batched.page { _ in }, "migration priority initial history request")
    check(entered.wait(timeout: .now() + 8) == .success, "legacy conversion paused inside real first batch")
    let fresh = RideSummary(started: date.addingTimeInterval(10), mode: "fresh")
    let beganAtWrites = Locked<Int?>(nil)
    check(batched.begin(fresh) { result in if case .success = result { beganAtWrites.set(writes.get()) } }, "fresh navigation recording queued during conversion")
    check(batched.append(fix(10, segment: true), to: fresh.id), "fresh point queued during migration")
    check(batched.finish(fresh.id, at: date.addingTimeInterval(11)), "fresh finish queued during migration")
    if deleteDuringMigration { check(batched.remove(batchLegacy.id) { _ in }, "old conversion delete queued") }
    release.signal(); batched.flushForTests(); batched.flushMigrationForTests()
    check(beganAtWrites.get() != nil && beganAtWrites.get()! <= 512, "fresh trip is processed after at most one conversion batch")
    let result = try page(batched)
    check(result.rides.first(where: { $0.id == fresh.id })?.pointCount == 1, "fresh track saved independently of legacy work")
    if deleteDuringMigration {
        check(!result.rides.contains(where: { $0.id == batchLegacy.id }) && !FileManager.default.fileExists(atPath: legacyFile.path), "migration cannot resurrect explicitly deleted old track")
        check(!FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent(".migrating-" + batchLegacy.id.uuidString).path), "cancelled migration staging cleaned")
    } else {
        check(result.rides.first(where: { $0.id == batchLegacy.id })?.pointCount == 2048, "yielded migration still saves every old point")
        let yieldedGPX = parse(try exported(batched, batchLegacy.id))
        check(yieldedGPX.points == 2048, "yielded migration complete GPX")
    }
}

// Metadata pagination has a fixed page size and stable UUID tie-breaking; no old
// track points are loaded just to show additional pages of history.
var pageLimits = RideStore.Limits(); pageLimits.pageSize = 7
let pages = RideStore(root: base.appendingPathComponent("pages"), limits: pageLimits)
var ids = Set<UUID>()
for i in 0..<23 {
    let item = RideSummary(started: date.addingTimeInterval(Double(i / 2)), mode: "page")
    ids.insert(item.id); check(pages.begin(item), "paged begin"); finish(pages, item.id)
}
var cursor: RideStore.Cursor?, seen = Set<UUID>(), pageCount = 0
repeat {
    let current = try page(pages, before: cursor); pageCount += 1
    check(current.rides.count <= 7, "history memory limited to requested page")
    for ride in current.rides { check(seen.insert(ride.id).inserted, "pagination does not repeat equal-date rows") }
    cursor = current.next
} while cursor != nil
check(seen == ids && pageCount == 4, "every old history record remains reachable through bounded pages")
let report: [String: Any] = ["schema": "motonav.ride-store.regression.v1", "platform": "ios", "passed": true,
    "checks": checks, "longTrackPoints": longCount, "gpxPoints": parsedLong.points, "gpxSegments": parsedLong.segments,
    "maximumReadBufferBytes": store.maximumReadBuffer, "maximumPendingOperations": bounded.maximumPendingOperations,
    "historyPageSize": 7, "pagedHistoryRecords": seen.count,
    "scope": "Real Foundation file store, append journal, streamed GPX and accelerated synthetic fixes; no live GPS, background OS, BLE or hardware test."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
print("RideStoreAA9: \(checks) checks passed; \(longCount) actual appended points, complete streamed GPX, FIFO sessions, crash prefix recovery, retained legacy migration, bounded history pages")

func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
