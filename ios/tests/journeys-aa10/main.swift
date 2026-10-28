import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}
func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError(message) } catch { checks += 1 }
}
let first = JourneyPoint(name: "加油站", lat: 30.1, lng: 120.1)
let second = JourneyPoint(name: "观景点", lat: 30.2, lng: 120.2)
let third = JourneyPoint(name: "午饭", lat: 30.3, lng: 120.3)
var draft = JourneyDraft([first, second, third])
draft.move(2, by: -1)
check(draft.points == [first, third, second], "move up preserves all ordered stops")
draft.move(0, by: 1)
check(draft.points == [third, first, second], "move down")
draft.remove(1)
check(draft.points == [third, second], "individual deletion")
draft.append(first, limit: 2)
check(draft.points.count == 2, "bounded draft")
draft.cancel()
check(draft.points == [first, second, third], "cancel restores committed order and deletion")
draft.move(-1, by: 1); draft.move(0, by: -1); draft.remove(99)
check(draft.points == draft.original, "invalid indexes are harmless")

// Production planning ownership is the same guard used by independent planning,
// imports and saved journeys. An unsuccessful replacement has no publish action.
let plans = RoutePlanningGeneration()
let old = plans.begin()
plans.invalidate() // opening a new editor invalidates pending work
let current = plans.begin() // one Apply, one query
check(!plans.finish(old) && plans.isBusy, "late old callback cannot finish new edit")
var installedVias = [first, second]
var installedRoute = "route-for-A-B"
check(plans.finish(current), "new result can finish")
let planningFailure: Result<String, Error> = .failure(JourneyStore.Failure("route service failed"))
check(!JourneyReplacement.apply(planningFailure, canCommit: { true }, commit: { candidate in installedVias = draft.points; installedRoute = candidate }), "failed query must reject commit")
check(installedVias == [first, second] && installedRoute == "route-for-A-B", "failed query leaves old snapshot intact")
let superseded = plans.begin(); plans.invalidate()
check(!plans.accepts(superseded), "stopped and restarted requests cannot publish")

// These are the production sheet leases used by both driving and independent
// planners, including invalidation by an imported/new candidate.
let editGenerations = RoutePlanningGeneration()
let drivingDraft = RouteDraftLease(generations: editGenerations)
let oldDraft = drivingDraft.begin()
check(editGenerations.isBusy, "draft blocks imports while visible")
editGenerations.invalidate() // a new candidate/session supersedes the sheet
var applies = 0
check(!drivingDraft.apply(oldDraft) { applies += 1 }, "old sheet cannot apply to new candidate")
let newRequest = editGenerations.begin()
check(drivingDraft.cancel(oldDraft), "old sheet may close")
check(editGenerations.accepts(newRequest) && editGenerations.isBusy, "old sheet dismissal cannot cancel new planning")
let newDraft = drivingDraft.begin()
check(drivingDraft.apply(newDraft) { applies += 1 }, "current sheet applies once")
check(!drivingDraft.apply(newDraft) { applies += 1 } && applies == 1, "duplicate apply cannot issue another query")
let independentDraft = RouteDraftLease(generations: editGenerations)
let independentOwner = independentDraft.begin()
let newerOwner = independentDraft.begin()
check(!independentDraft.cancel(independentOwner) && editGenerations.isBusy, "old independent dismissal cannot unlock newer editor")
check(independentDraft.cancel(newerOwner) && !editGenerations.isBusy, "current independent cancel releases lease")

let confirmSession = UUID(), confirmRoute = UUID()
let expectedStop = JourneySkipIntent(session: confirmSession, route: confirmRoute, cursor: 0)
check(JourneyConfirmation.matches(expectedStop, current: expectedStop, active: true), "unchanged next stop may be confirmed")
check(!JourneyConfirmation.matches(expectedStop, current: JourneySkipIntent(session: confirmSession, route: confirmRoute, cursor: 1), active: true), "naturally passing original next stop while dialog is open must not skip its successor")
check(!JourneyConfirmation.matches(expectedStop, current: JourneySkipIntent(session: confirmSession, route: UUID(), cursor: 0), active: true), "same cursor on replacement route is a different next stop")
check(!JourneyConfirmation.matches(expectedStop, current: JourneySkipIntent(session: UUID(), route: confirmRoute, cursor: 0), active: true), "confirmation cannot target a newer session")
check(!JourneyConfirmation.matches(expectedStop, current: expectedStop, active: false), "arrival while confirmation is open cancels action")
check(!JourneyConfirmation.matches(Optional<JourneySkipIntent>.none, current: expectedStop, active: true), "missing captured intent cannot confirm")
check(JourneyConfirmation.matches(Optional(confirmSession), current: Optional(confirmSession), active: true), "same session exit allowed even when route changes")
check(!JourneyConfirmation.matches(Optional(confirmSession), current: Optional(UUID()), active: true), "stale exit dialog cannot stop a newly started independent session")
check(!JourneyConfirmation.matches(Optional(UInt64(7)), current: Optional(UInt64(8)), active: true), "stale drive close menu or long press cannot stop newer SDK session")

let transaction = JourneyTransaction(), owner = UUID()
let skip = transaction.begin(owner: owner, cursor: 1)
func accepts(_ ticket: JourneyTransaction.Ticket, owner value: UUID = owner, cursor: Int = 1,
             running: Bool = true, fresh: Bool = true, moved: Double = 20) -> Bool {
    transaction.accepts(ticket, owner: value, cursor: cursor, running: running, freshFix: fresh, movedMetres: moved)
}
check(accepts(skip), "successful manual skip retains request ownership")
check(!accepts(skip, owner: UUID()), "new session rejects old result")
check(!accepts(skip, cursor: 2), "passing the next stop rejects in-flight skip")
check(!accepts(skip, running: false), "stopped navigation rejects skip")
check(!accepts(skip, fresh: false), "stale phone fix rejects skip")
check(!accepts(skip, moved: 100.1), "movement over100m rejects skip")
check(!accepts(skip, moved: .nan), "invalid distance rejects skip")
check(!accepts(skip, moved: -1), "negative distance rejects skip")
check(accepts(skip, moved: 100), "100m boundary")
var effectiveRoute = "original"
check(!JourneyReplacement.apply(planningFailure, canCommit: { accepts(skip) }, commit: { effectiveRoute = $0 }), "skip failure cannot install")
check(effectiveRoute == "original", "network failure continues old guidance")
check(!JourneyReplacement.apply(.success("stale route"), canCommit: { accepts(skip, owner: UUID()) }, commit: { effectiveRoute = $0 }), "successful network response still needs owner guard")
check(effectiveRoute == "original", "owner rejection leaves guidance intact")
let newerSkip = transaction.begin(owner: owner, cursor: 1)
check(!accepts(skip) && accepts(newerSkip), "later skip owns the completion")
check(JourneyReplacement.apply(.success("skipped"), canCommit: { accepts(newerSkip) }, commit: { effectiveRoute = $0; transaction.invalidate() }), "valid skip commits")
check(effectiveRoute == "skipped" && !accepts(newerSkip), "successful commit cannot be applied twice")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motonav-journeys-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("journeys.json"), store = JourneyStore(url: directory.appendingPathComponent("journeys.json"))
check((try? store.load())?.isEmpty == true, "missing file is empty library")
let journey = SavedJourney(name: "周末山路", mode: .motorcycle, destination: third, vias: [first, second], avoidHighway: false)
try store.save([journey])
check((try? store.load()) == [journey], "roundtrip retains name destination order and mode")
let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
for field in ["\"version\":1", "\"id\"", "\"name\"", "\"mode\"", "\"destination\"", "\"vias\"", "\"avoidHighway\"", "\"createdAtMs\""] {
    check(json.contains(field), "cross-platform field \(field)")
}
for forbidden in ["start", "coordinate", "SDK", "geometry", "routeID", "cookie", "token"] {
    check(!json.contains(forbidden), "itinerary never persists \(forbidden)")
}
var renamed = journey; renamed.name = "另一个周末"
let failingStore = JourneyStore(url: url, write: { _, _ in throw JourneyStore.Failure("injected disk failure") })
rejects("atomic write must be visible") { try failingStore.save([renamed]) }
check((try? store.load()) == [journey], "write failure preserves earlier valid file")
rejects("delete failure must be visible") { try failingStore.save([]) }
check((try? store.load()) == [journey], "failed delete leaves library intact")
var invalid = journey; invalid.name = " "
rejects("empty name") { try store.save([invalid]) }
invalid.name = String(repeating: "路", count: 81)
rejects("bounded name") { try store.save([invalid]) }
invalid = journey; invalid.destination.lat = .infinity
rejects("finite coordinates") { try store.save([invalid]) }
invalid = journey; invalid.destination.lng = 181
rejects("valid longitude") { try store.save([invalid]) }
invalid = journey; invalid.vias = Array(repeating: first, count: JourneyMode.motorcycle.maximumVias + 1)
rejects("maximum vias") { try store.save([invalid]) }
invalid = journey; invalid.mode = .bicycle
rejects("bicycle vias are unsupported, never silently dropped") { try store.save([invalid]) }
invalid.vias = []
check(invalid.isValid, "bicycle endpoint-only journey")
rejects("duplicate identities") { try store.save([journey, journey]) }
var many: [SavedJourney] = []
for i in 0..<31 { var item = journey; item.id = UUID(); item.name = "行程\(i)"; many.append(item) }
rejects("bounded library") { try store.save(many) }
try Data("{corrupt".utf8).write(to: url)
rejects("damaged file surfaces error") { _ = try store.load() }
try Data(repeating: 0x20, count: JourneyStore.maximumBytes + 1).write(to: url)
rejects("oversized file rejected before decode") { _ = try store.load() }
let now = Date()
check(NavigationRecoveryCheckpoint.acceptsFix(lat: 30, lng: 120, accuracy: 10, timestamp: now), "fresh origin allowed")
check(!NavigationRecoveryCheckpoint.acceptsFix(lat: 30, lng: 120, accuracy: 10, timestamp: now.addingTimeInterval(-16)), "stored GPS origin forbidden")
checks += runNativeIntentRegression()
print("journeys-aa10: \(checks) checks passed")
