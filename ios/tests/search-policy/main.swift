import Foundation

typealias Policy = SearchRequestPolicy<String>
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
let now = Date(timeIntervalSince1970: 1_700_000_000)
let nearby = Policy.Coordinate(latitude: 31.231, longitude: 121.471)
let sameArea = Policy.Coordinate(latitude: 31.235, longitude: 121.475)
let moved = Policy.Coordinate(latitude: 31.271, longitude: 121.511)

func request(_ policy: inout Policy, _ text: String, _ point: Policy.Coordinate? = nearby,
             at date: Date = now) -> Policy.Ticket {
    guard case .request(let ticket) = policy.begin(query: text, nearby: point, now: date) else {
        preconditionFailure("Expected a new SDK request: \(text)")
    }
    return ticket
}
func cached(_ policy: inout Policy, _ text: String, _ point: Policy.Coordinate? = nearby,
            at date: Date = now) -> [String]? {
    if case .cached(let values) = policy.begin(query: text, nearby: point, now: date) { return values }
    return nil
}

// Both success and failure must obey generation order, including identical repeated text.
var policy = Policy()
let a = request(&policy, "医院")
let b = request(&policy, "加油站")
check(!policy.succeed(a, values: ["旧医院"], now: now), "An old success cannot replace a new keyword")
check(!policy.fail(a), "An old failure cannot replace the new searching state")
check(policy.succeed(b, values: ["附近加油站"], now: now), "The current result is accepted")
check(!policy.fail(b), "A duplicate failure cannot replace completed results")
check(!policy.succeed(b, values: ["重复"], now: now), "A duplicate success cannot rewrite the cache")
check(cached(&policy, " 加油站\n") == ["附近加油站"], "Whitespace-normalized cached search is reused")
check(policy.cachedCount == 1, "Rejected old results never enter the cache")

let same1 = request(&policy, "服务区")
let same2 = request(&policy, "服务区")
check(same1 != same2, "Identical text still gets a unique request ticket")
check(!policy.succeed(same1, values: ["旧服务区"], now: now), "Same-keyword old success is rejected")
check(!policy.fail(same1), "Same-keyword old failure is rejected")
check(policy.fail(same2), "The current failure is accepted")
check(!policy.succeed(same2, values: ["迟到结果"], now: now), "Success after failure is ignored")

// Editing, clearing, selecting a result or leaving the picker all invalidate outstanding work.
for action in ["editing", "clear", "selection", "dismiss"] {
    let pending = request(&policy, action)
    policy.invalidate()
    check(!policy.succeed(pending, values: ["过期结果"], now: now), "\(action) discards a pending success")
    check(!policy.fail(pending), "\(action) discards a pending failure")
}
let pendingBeforeEmpty = request(&policy, "餐厅")
if case .empty = policy.begin(query: " \n", nearby: nearby, now: now) {
    check(true, "An empty search clears without issuing a request")
} else { check(false, "Empty search must not request") }
check(!policy.succeed(pendingBeforeEmpty, values: ["餐厅"], now: now), "Empty input cannot refill from an expired callback")

// Cached hits invalidate pending requests too, even if the pending keyword differs.
let staleWhileCacheHit = request(&policy, "车行")
check(cached(&policy, "加油站") == ["附近加油站"], "Selecting a cached query completes immediately")
check(!policy.succeed(staleWhileCacheHit, values: ["车行"], now: now), "An older request cannot overwrite a cache hit")
check(!policy.fail(staleWhileCacheHit), "An older failure cannot overwrite a cache hit")

// Area and global searches are distinct. Fresh locations in one cell can reuse short-lived results.
check(cached(&policy, "加油站", sameArea) == ["附近加油站"], "Same nearby cell reuses the short-lived cache")
let newArea = request(&policy, "加油站", moved)
check(policy.succeed(newArea, values: ["新城区加油站"], now: now), "A moved region gets new results")
check(cached(&policy, "加油站", nearby) == ["附近加油站"], "Moving does not overwrite the original area's cache")
check(cached(&policy, "加油站", moved) == ["新城区加油站"], "The new area's cache stays isolated")
let global = request(&policy, "加油站", nil)
check(policy.succeed(global, values: ["无附近偏好的结果"], now: now), "Search without a usable fix has a separate key")
check(cached(&policy, "加油站", nil) == ["无附近偏好的结果"], "Global results can be reused without stale coordinates")
check(cached(&policy, "加油站", nearby) == ["附近加油站"], "Global results do not pollute a nearby key")

// Five-minute TTL is measured from completion, never extended by reads.
check(cached(&policy, "加油站", nearby, at: now.addingTimeInterval(299)) == ["附近加油站"], "Results live for less than five minutes")
let expired = request(&policy, "加油站", nearby, at: now.addingTimeInterval(300))
check(policy.succeed(expired, values: ["重新获取"], now: now.addingTimeInterval(300)), "At TTL a new request replaces expired data")
check(cached(&policy, "加油站", nearby, at: now.addingTimeInterval(301)) == ["重新获取"], "Freshly fetched data starts a new TTL")
let emptyResult = request(&policy, "不存在的地点", nearby, at: now.addingTimeInterval(301))
check(policy.succeed(emptyResult, values: [], now: now.addingTimeInterval(301)), "A valid empty result is cacheable")
check(cached(&policy, "不存在的地点", nearby, at: now.addingTimeInterval(302)) == [], "Empty result cache avoids duplicate quota use")
let backwardsClock = request(&policy, "加油站", nearby, at: now.addingTimeInterval(299))
check(policy.fail(backwardsClock), "Clock rollback discards future-dated cache rather than keeping it forever")

// Changing Key invalidates results, all pending callbacks and previously cached errors/empty data.
let beforeKeyChange = request(&policy, "停车场", nearby, at: now.addingTimeInterval(302))
policy.reset()
check(policy.cachedCount == 0, "Key changes clear all cached results")
check(!policy.succeed(beforeKeyChange, values: ["旧 Key 结果"], now: now), "A callback from a previous key is rejected")
check(!policy.fail(beforeKeyChange), "An error from a previous key is rejected")
let afterKeyChange = request(&policy, "加油站")
check(policy.succeed(afterKeyChange, values: ["新 Key 结果"], now: now), "A new key may search an old keyword again")

// LRU capacity stays bounded and failed requests do not poison the cache.
var bounded = Policy(capacity: 3)
for name in ["A", "B", "C"] {
    let ticket = request(&bounded, name)
    check(bounded.succeed(ticket, values: [name], now: now), "Store bounded entry \(name)")
}
check(cached(&bounded, "A") == ["A"], "A cache read refreshes its LRU priority")
let d = request(&bounded, "D")
check(bounded.succeed(d, values: ["D"], now: now), "A fourth entry can be stored")
check(bounded.cachedCount == 3, "Cache capacity is bounded")
check(cached(&bounded, "A") == ["A"], "Recently read A survives eviction")
check(cached(&bounded, "C") == ["C"], "C survives eviction")
check(cached(&bounded, "D") == ["D"], "The latest D survives eviction")
let evicted = request(&bounded, "B")
check(bounded.fail(evicted), "The least-recent B must be fetched again")
let failedAgain = request(&bounded, "B")
check(bounded.fail(failedAgain), "Failures are not cached as successful empty results")

// Separate picker instances do not share generations, cached results or selected regions.
var pickerOne = Policy(), pickerTwo = Policy()
let one = request(&pickerOne, "医院"), two = request(&pickerTwo, "医院")
check(one != two, "Separate pickers use independent tickets")
pickerOne.invalidate()
check(pickerTwo.succeed(two, values: ["另一个窗口"], now: now), "Clearing one picker cannot cancel another")
check(!pickerOne.succeed(one, values: ["已清空的窗口"], now: now), "The cleared picker stays empty")
check(pickerOne.cachedCount == 0 && pickerTwo.cachedCount == 1, "Separate pickers have independent caches")

// CLLocation can remain in memory after authorization is revoked or the last fix expires.
func fix(_ age: Double = 1, accuracy: Double = 30, authorized: Bool = true,
         latitude: Double = nearby.latitude, longitude: Double = nearby.longitude) -> Policy.LocationFix {
    .init(coordinate: .init(latitude: latitude, longitude: longitude),
          timestamp: now.addingTimeInterval(-age), accuracy: accuracy, authorized: authorized)
}
check(Policy.nearbyCoordinate(fix(), now: now) == nearby, "Fresh authorized location can bias the SDK search")
check(Policy.nearbyCoordinate(fix(20), now: now) == nearby, "A twenty-second fix is still usable")
check(Policy.nearbyCoordinate(fix(21), now: now) == nil, "Expired location is omitted")
check(Policy.nearbyCoordinate(fix(-6), now: now) == nil, "Future-dated location is omitted")
check(Policy.nearbyCoordinate(fix(authorized: false), now: now) == nil, "Revoked authorization omits retained coordinates")
check(Policy.nearbyCoordinate(nil, now: now) == nil, "No location is a normal global search")
check(Policy.nearbyCoordinate(fix(accuracy: -1), now: now) == nil, "Invalid accuracy is omitted")
check(Policy.nearbyCoordinate(fix(accuracy: 3_001), now: now) == nil, "Excessively inaccurate coordinates are omitted")
check(Policy.nearbyCoordinate(fix(accuracy: 2_000), now: now) == nearby, "A usable approximate location can bias nearby results")
check(Policy.nearbyCoordinate(fix(latitude: .nan), now: now) == nil, "NaN latitude is rejected")
check(Policy.nearbyCoordinate(fix(longitude: .infinity), now: now) == nil, "Infinite longitude is rejected")
check(Policy.nearbyCoordinate(fix(latitude: 91), now: now) == nil, "Out-of-range latitude is rejected")
check(Policy.nearbyCoordinate(fix(longitude: -181), now: now) == nil, "Out-of-range longitude is rejected")
check(Policy.cacheKey(query: "医院", nearby: .init(latitude: .nan, longitude: 10)) == Policy.cacheKey(query: "医院", nearby: nil), "Malformed coordinates cannot crash cache quantization")

print("Search request policy: \(checks) checks passed")
