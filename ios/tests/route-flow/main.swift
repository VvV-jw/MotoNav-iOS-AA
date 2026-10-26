import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
struct Point: Equatable { let name: String; let lat: Double; let lng: Double }
let previousFix = Point(name: "我的位置", lat: 31.2, lng: 121.4)
let newFix = Point(name: "我的位置", lat: 31.22, lng: 121.42)
let selectedPlace = Point(name: "加油站", lat: 31.3, lng: 121.5)

// Reopening is driven by provenance, never the text of the place or a persisted
// coordinate. Changing destination after moving must resolve the new phone fix.
let reopenedCurrent = RouteOriginSelection(source: .currentLocation, plannedStart: previousFix)
check(reopenedCurrent.selectedPlace == nil, "a query's old phone fix is not a fixed planner origin")
check(reopenedCurrent.resolve { newFix } == newFix, "reopened current origin follows the moved device")
check(reopenedCurrent.resolve { nil } == nil, "missing fresh location cannot fall back to the previous query's coordinate")
check(reopenedCurrent.source == .currentLocation, "dynamic origin intent survives reopening")

var manual = RouteOriginSelection(selectedPlace: selectedPlace)
var locationQueries = 0
check(manual.resolve { locationQueries += 1; return newFix } == selectedPlace, "hand-selected origin is preserved")
check(locationQueries == 0, "a selected place does not depend on live location availability")
let reopenedManual = RouteOriginSelection(source: manual.source, plannedStart: selectedPlace)
check(reopenedManual.selectedPlace == selectedPlace, "reopening keeps the hand-selected start")
let identicallyNamed = RouteOriginSelection(source: .selectedPlace, plannedStart: previousFix)
check(identicallyNamed.selectedPlace == previousFix, "a manually selected place named My Location is still fixed")
manual.selectedPlace = nil
check(manual.source == .currentLocation && manual.resolve { newFix } == newFix, "Use current location clears the manual selection")

let idle = RouteSessionAvailability()
check(idle.canInstallCandidate(), "idle session accepts a candidate")
let busy: [RouteSessionAvailability] = [
    .init(independentNavigation: true), .init(driveNavigation: true), .init(cruising: true),
    .init(drivePlanning: true), .init(recovering: true), .init(independentPlanning: true), .init(cruising: true, recovering: true)
]
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-route-flow-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let store = NavigationRecoveryStore(url: directory.appendingPathComponent("trip.json"))
let now = Date(timeIntervalSince1970: 1_800_000_000)
let old = NavigationRecoveryCheckpoint(mode: .drive, destination: .init(name: "旧目的地", lat: 31, lng: 121),
    avoidHighway: false, savedAt: now)
let replacement = NavigationRecoveryCheckpoint(mode: .bicycle, destination: .init(name: "新目的地", lat: 32, lng: 122),
    avoidHighway: true, savedAt: now)
check(store.save(old, now: now), "fixture checkpoint saved")
let originalBytes = try Data(contentsOf: store.url)
for session in busy {
    var releases = 0, persists = 0
    let accepted = RouteCandidateCommit.install(session: session,
        candidate: { releases += 1; store.clear(); return true },
        persist: { persists += 1; _ = store.save(replacement, now: now) })
    check(!accepted, "navigation, cruise or busy planning rejects candidate installation")
    check(releases == 0 && persists == 0, "a rejected candidate never clears SDK state or saves a checkpoint")
    let retainedBytes = try Data(contentsOf: store.url)
    check(retainedBytes == originalBytes, "rejected candidate leaves previous checkpoint byte-identical")
    check(store.load(now: now) == old, "restart still sees the original itinerary after rejection")
}
var persistedOnReleaseFailure = false
check(!RouteCandidateCommit.install(session: idle, candidate: { false }, persist: { persistedOnReleaseFailure = true }),
    "failed SDK handoff rejects installation")
check(!persistedOnReleaseFailure && store.load(now: now) == old, "failed engine handoff cannot overwrite the checkpoint")
check(!RouteSessionAvailability(cruising: true, recovering: true).canInstallCandidate(finishingRecovery: true),
    "finishing recovery cannot override an active cruise")
check(!RouteSessionAvailability(drivePlanning: true, recovering: true).canInstallCandidate(finishingRecovery: true),
    "finishing recovery cannot override another drive query")
var installed = false
check(RouteCandidateCommit.install(session: .init(recovering: true), finishingRecovery: true,
    candidate: { installed = true; store.clear(); return true },
    persist: { check(installed, "candidate is installed before its checkpoint is written"); _ = store.save(replacement, now: now) }),
    "recovery may finish its own query as an idle candidate")
check(store.load(now: now) == replacement, "accepted candidate replaces the recovery itinerary")

let generation = RoutePlanningGeneration()
let initial = generation.begin()
check(generation.accepts(initial) && generation.isBusy, "new query owns the route generation and keeps imports out")
let newer = generation.begin()
check(!generation.accepts(initial) && generation.accepts(newer), "latest query wins across planning screens")
generation.cancel(initial)
check(generation.accepts(newer) && generation.isBusy, "an old planner disappearing cannot cancel a newer query")
check(!generation.finish(initial) && generation.isBusy, "old completion cannot unlock a newer pending query")
check(generation.finish(newer) && !generation.isBusy && generation.accepts(newer), "current reply releases planning before candidate installation")
generation.invalidate() // start another mode
generation.invalidate() // stop it before old HTTP reply
check(!generation.accepts(newer), "a mode that starts and stops still invalidates an earlier reply")
let recovered = generation.begin()
generation.invalidate() // dismiss recovery or select imported destination
check(!generation.accepts(recovered), "discarded recovery cannot resurrect an older route")
print("PASS route origin provenance, idle candidate commit, checkpoint preservation and cross-session replies (\(checks) checks)")
