import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("GTA service gate check \(checks + 1): \(label)") }; checks += 1
}
final class Clock {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
}
final class Counter {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let clock = Clock(), requests = Counter(), gate = GtaServiceGate(now: { clock.now() })
func rejected(_ status: Int, until: Date, _ work: () throws -> Void) {
    do { try work(); fatalError("Expected typed HTTP cooldown") }
    catch MapServiceError.http(let actual, let retryAfter) {
        check(actual == status, "HTTP status classification retained")
        check(abs(clock.now().addingTimeInterval(retryAfter ?? 60).timeIntervalSince(until)) < 0.0001,
              "blocked fetch reports original absolute deadline")
    } catch { fatalError("Unexpected gate error: \(error)") }
}
func staleFallback() throws -> Data {
    do { return try gate.fetch { requests.increment(); fatalError("Old cache fallback bypassed provider gate") } }
    catch MapServiceError.http { return Data([7, 8, 9]) }
}
let start = clock.now(), until = start.addingTimeInterval(90)
rejected(429, until: until) {
    let _: Data = try gate.fetch { requests.increment(); throw MapServiceError.http(status: 429, retryAfter: 90) }
}
check(gate.retryAt == until && requests.value == 1, "429 installs provider-wide cooldown")
for build in 1...5 {
    clock.set(start.addingTimeInterval(Double(build)))
    let old = try staleFallback()
    check(old == Data([7, 8, 9]), "other route blocks retain validated old raw data")
    rejected(429, until: until) {
        let _: String = try gate.fetch { requests.increment(); return "force/new-build/manifest" }
    }
    check(gate.retryAt == until, "new build/force/manifest does not reset or extend fixed deadline")
}
check(requests.value == 1, "blocked fetches never touch underlying service")
clock.set(until.addingTimeInterval(-0.001))
rejected(429, until: until) { let _: String = try gate.fetch { requests.increment(); return "new-revision" } }
clock.set(until)
let resumed: String = try gate.fetch { requests.increment(); return "resumed" }
check(resumed == "resumed" && gate.retryAt == nil && requests.value == 2, "fetch resumes exactly at deadline")
let fallback = clock.now().addingTimeInterval(60)
rejected(503, until: fallback) { let _: Data = try gate.fetch { throw MapServiceError.http(status: 503, retryAfter: nil) } }
clock.set(until.addingTimeInterval(20))
rejected(503, until: fallback) { let _: String = try gate.fetch { "force" } }
check(gate.retryAt == fallback, "missing header defaults once, without a sliding deadline")
clock.set(fallback)
do { let _: Data = try gate.fetch { throw MapServiceError.http(status: 401, retryAfter: nil) }; fatalError("401 accepted") }
catch MapServiceError.http(let status, _) { check(status == 401 && gate.retryAt == nil, "authorization is outside provider cooldown gate") }
do { let _: Data = try gate.fetch { throw URLError(.notConnectedToInternet) }; fatalError("Offline accepted") }
catch { check(gate.retryAt == nil, "ordinary network failure never becomes service cooldown") }

for header in ["0", "Sun, 01 Jan 2023 00:00:00 GMT"] {
    let minimum = clock.now().addingTimeInterval(1), previousRequests = requests.value
    let seconds = MapFailurePolicy.retryAfter(header, now: clock.now())
    rejected(429, until: minimum) {
        let _: Data = try gate.fetch { requests.increment(); throw MapServiceError.http(status: 429, retryAfter: seconds) }
    }
    check(gate.retryAt == minimum, "zero/past hint still establishes one-second provider floor")
    clock.set(minimum.addingTimeInterval(-0.5))
    rejected(429, until: minimum) { let _: String = try gate.fetch { requests.increment(); return "stale-build" } }
    check(requests.value == previousRequests + 1 && gate.retryAt == minimum, "zero/past hint cannot hammer or slide through stale fallback")
    clock.set(minimum)
}

let concurrent = GtaServiceGate(now: { clock.now() }), entered = DispatchGroup(), finished = DispatchGroup()
let response = DispatchSemaphore(value: 0)
for seconds in [2.0, 10.0, 5.0, 20.0] {
    entered.enter(); finished.enter()
    DispatchQueue.global().async {
        defer { finished.leave() }
        do {
            let _: Data = try concurrent.fetch {
                entered.leave()
                guard response.wait(timeout: .now() + 5) == .success else { fatalError("In-flight response barrier") }
                throw MapServiceError.http(status: 503, retryAfter: seconds)
            }
        } catch { }
    }
}
check(entered.wait(timeout: .now() + 5) == .success, "all in-flight requests started before first response")
for _ in 0..<4 { response.signal() }
check(finished.wait(timeout: .now() + 5) == .success, "concurrent provider responses completed")
check(concurrent.retryAt == clock.now().addingTimeInterval(20), "concurrent responses preserve longest provider deadline")
print("GtaServiceGate: \(checks) checks passed; fixed deadlines, cached fallback, shared fetch suppression")
