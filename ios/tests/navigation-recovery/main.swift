import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
let destination = NavigationRecoveryCheckpoint.Point(name: "测试目的地", lat: 31.25, lng: 121.5)
let stopA = NavigationRecoveryCheckpoint.Point(name: "加油站", lat: 31.2, lng: 121.45)
let stopB = NavigationRecoveryCheckpoint.Point(name: "休息点", lat: 31.22, lng: 121.46)
let checkpoint = NavigationRecoveryCheckpoint(mode: .drive, destination: destination, vias: [stopA, stopB], avoidHighway: true, savedAt: now)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-recovery-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("session.json")
let store = NavigationRecoveryStore(url: file)
check(store.load(now: now) == nil, "first launch has no itinerary")
check(store.save(checkpoint, now: now), "save planned itinerary")
// A new store instance represents process death/restart. The result is only a
// checkpoint: there is intentionally no route ID, live instruction or start flag.
let restarted = NavigationRecoveryStore(url: file)
check(restarted.load(now: now) == checkpoint, "restart recovers destination, ordered stops and highway preference")
let encoded = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let allowed: Set<String> = ["version", "id", "savedAt", "mode", "destination", "vias", "avoidHighway", "importedRoute"]
check(Set(encoded.keys).isSubset(of: allowed), "checkpoint never persists GPS, turn direction, simulation or SDK state")
check(encoded["navigating"] == nil && encoded["position"] == nil && encoded["selectedRouteID"] == nil, "loading cannot arm navigation")

let changed = NavigationRecoveryCheckpoint(mode: .motorcycle, destination: stopB, vias: [stopA], avoidHighway: false, savedAt: now)
check(store.save(changed, now: now), "replace driving session with motorcycle request")
check(restarted.load(now: now) == changed, "latest successful checkpoint owns recovery; there is no second trip")
let afterStop = NavigationRecoveryCheckpoint(mode: .motorcycle, destination: stopB, vias: [], avoidHighway: false, savedAt: now)
check(store.save(afterStop, now: now), "persist passed via removal")
check(restarted.load(now: now)?.vias.isEmpty == true, "passed stop does not send recovery backwards")
store.clear()
check(restarted.load(now: now) == nil, "explicit exit, arrival or dismissal cannot resurrect a trip")
store.clear()
check(!FileManager.default.fileExists(atPath: file.path), "clearing is idempotent")

check(store.save(checkpoint, now: now), "restore fixture after stop")
check(restarted.load(now: now.addingTimeInterval(NavigationRecoveryCheckpoint.maximumAge)) == checkpoint, "exact age limit accepted")
check(restarted.load(now: now.addingTimeInterval(NavigationRecoveryCheckpoint.maximumAge + 1)) == nil, "old route expires")
check(!FileManager.default.fileExists(atPath: file.path), "expired itinerary is removed")
check(!store.save(NavigationRecoveryCheckpoint(mode: .drive, destination: destination, avoidHighway: true,
    savedAt: now.addingTimeInterval(301)), now: now), "future clock corruption is rejected")

try! Data("{ broken checkpoint".utf8).write(to: file)
check(restarted.load(now: now) == nil, "truncated JSON does not break launch")
check(!FileManager.default.fileExists(atPath: file.path), "corrupt file removed")
var unknown = encoded; unknown["version"] = 99
try! JSONSerialization.data(withJSONObject: unknown).write(to: file)
check(restarted.load(now: now) == nil, "unknown future schema is ignored safely")
var badCoordinate = encoded
badCoordinate["destination"] = ["name": "invalid", "lat": 91, "lng": 0] as [String: Any]
try! JSONSerialization.data(withJSONObject: badCoordinate).write(to: file)
check(restarted.load(now: now) == nil, "out-of-range coordinate cannot reach the planner")
var unknownMode = encoded; unknownMode["mode"] = "hovercraft"
try! JSONSerialization.data(withJSONObject: unknownMode).write(to: file)
check(restarted.load(now: now) == nil, "unknown mode cannot fall back to driving")
try! Data(repeating: 32, count: NavigationRecoveryStore.maximumBytes + 1).write(to: file)
check(restarted.load(now: now) == nil, "oversized corrupt file rejected before JSON decoding")
check(!FileManager.default.fileExists(atPath: file.path), "oversized file removed")

for (lat, lng) in [(Double.nan, 0.0), (0, Double.infinity), (90.001, 0), (0, -180.001)] {
    let bad = NavigationRecoveryCheckpoint(mode: .drive, destination: .init(name: "bad", lat: lat, lng: lng), avoidHighway: true, savedAt: now)
    check(!store.save(bad, now: now), "invalid/non-finite destination rejected")
}
check(!store.save(NavigationRecoveryCheckpoint(mode: .drive, destination: destination,
    vias: [stopA, stopA, stopA, stopA], avoidHighway: true, savedAt: now), now: now), "SDK via limit enforced")
check(!store.save(NavigationRecoveryCheckpoint(mode: .bicycle, destination: destination,
    vias: [stopA], avoidHighway: true, savedAt: now), now: now), "bicycle cannot silently ignore a stored via")
check(!store.save(NavigationRecoveryCheckpoint(mode: .motorcycle, destination: destination,
    vias: Array(repeating: stopA, count: 17), avoidHighway: true, savedAt: now), now: now), "motorcycle via limit enforced")

let imported = NavigationRecoveryCheckpoint.ImportedRoute(start: stopA, end: destination,
    points: [stopA, stopB, destination], roads: [.init(name: "测试道路", length: 1000, points: [stopA, stopB, destination])],
    distance: 1000, seconds: 90, lights: 2, restored: true, kind: "摩托车")
let shared = NavigationRecoveryCheckpoint(mode: .drive, destination: destination, avoidHighway: false, importedRoute: imported, savedAt: now)
check(store.save(shared, now: now), "imported shape and metadata are preserved for fresh planning")
check(restarted.load(now: now) == shared, "restart retains imported polyline and original road names")
check(!store.save(NavigationRecoveryCheckpoint(mode: .drive, destination: stopB,
    avoidHighway: false, importedRoute: imported, savedAt: now), now: now), "imported endpoint must match selected destination")
let bicycleImport = NavigationRecoveryCheckpoint(mode: .bicycle, destination: destination, avoidHighway: false,
    importedRoute: imported, savedAt: now)
check(store.save(bicycleImport, now: now), "independent imported outline remains an itinerary, never old turn data")
check(restarted.load(now: now)?.mode == .bicycle, "imported bicycle plan retains its planning mode")

func accepts(_ lat: Double = 31.2, _ lng: Double = 121.4, accuracy: Double = 20, age: TimeInterval = 0) -> Bool {
    NavigationRecoveryCheckpoint.acceptsFix(lat: lat, lng: lng, accuracy: accuracy, timestamp: now.addingTimeInterval(-age), now: now)
}
check(accepts(), "current usable phone fix is accepted")
check(accepts(accuracy: 100, age: 15), "accuracy and age boundary accepted")
check(!accepts(age: 15.001), "stale phone fix is rejected")
check(!accepts(age: -2.001), "future fix is rejected")
check(!accepts(accuracy: -1), "invalid accuracy rejected")
check(!accepts(accuracy: 100.001), "imprecise fix rejected")
check(!accepts(accuracy: .nan), "non-finite accuracy rejected")
check(!accepts(.nan), "non-finite location rejected")
check(!accepts(91), "out-of-range recovery location rejected")

let gate = NavigationRecoveryGate()
let first = gate.begin(checkpoint.id)
check(gate.accepts(first, pendingID: checkpoint.id), "explicit recovery action accepts its own result")
check(!gate.accepts(first, pendingID: nil), "dismissing the pending card blocks late network output")
check(!gate.accepts(first, pendingID: changed.id), "replacing the checkpoint blocks another itinerary's result")
gate.invalidate()
check(!gate.accepts(first, pendingID: checkpoint.id), "stop/start/new plan invalidates an outstanding recovery attempt")
let second = gate.begin(checkpoint.id)
check(gate.accepts(second, pendingID: checkpoint.id), "a deliberate retry can run after a failure")
check(!gate.accepts(first, pendingID: checkpoint.id), "retry cannot resurrect the first request")
let third = gate.begin(changed.id)
check(gate.accepts(third, pendingID: changed.id), "new independent mode owns the recovery gate")
check(!gate.accepts(second, pendingID: checkpoint.id), "previous mode cannot publish after a new action")

let blocked = directory.appendingPathComponent("not-a-directory")
try! Data([0]).write(to: blocked)
let unwritable = NavigationRecoveryStore(url: blocked.appendingPathComponent("session.json"))
check(!unwritable.save(checkpoint, now: now), "file-system failure is reported without a crash")
check(unwritable.load(now: now) == nil, "failed persistence does not synthesize a session")
print("navigation-recovery: \(checks) checks passed")
