import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL offline-policy after \(checks) checks: \(message)\n".utf8))
        fatalError(message)
    }
    checks += 1
}
typealias Policy = OfflinePreparationPolicy
let distances = (0...100).map { Double($0) * 600 }
let date = Date(timeIntervalSince1970: 1_800_000_000)
let middle = Policy.window(distances: distances, target: 10, rangeKm: 5)
check(middle.indexes == Array(8...19), "5 km window includes two previous nodes and the first endpoint beyond 5 km")
check(middle.priority == Array(10...19) + [8, 9], "Forward blocks are prepared before retained rear blocks")
check(Policy.window(distances: distances, target: 0, rangeKm: 5).indexes == Array(0...9), "Start window clamps its lower edge")
check(Policy.window(distances: distances, target: 98, rangeKm: 5).indexes == Array(96...100), "End window clamps its upper edge")
check(Policy.window(distances: distances, target: 10, rangeKm: 0).indexes == Array(0...100), "Whole-route mode remains the default")
check(Policy.window(distances: distances, target: 10, rangeKm: 20).indexes == Array(8...44), "20 km uses route distance rather than a fixed node count")
check(Policy.window(distances: distances, target: 10, rangeKm: 50).indexes == Array(8...94), "50 km includes its covering endpoint")
check(Policy.window(distances: [0, 1000, 5000, 5001], target: 0, rangeKm: 5).indexes == [0, 1, 2], "An exact endpoint is included without unnecessarily taking the next block")
check(Policy.window(distances: [], target: 9, rangeKm: 5).priority.isEmpty, "Empty plans have no work")
check(Policy.window(distances: distances, target: -99, rangeKm: 5).target == 0, "Negative target clamps to the beginning")
check(Policy.window(distances: distances, target: 999, rangeKm: 5).target == 100, "Past-end target clamps to the destination")
check(Policy.window(distances: distances, target: 10, rangeKm: -5).rangeKm == 0, "Invalid ranges fall back to the whole route")

for range in Policy.rangesKm {
    for target in 0...100 {
        let window = Policy.window(distances: distances, target: target, rangeKm: range)
        check(Set(window.priority) == Set(window.indexes), "Every window node appears in priority order")
        check(Set(window.priority).count == window.priority.count, "No block appears twice")
        check(window.priority.first == target, "The current target is first")
        check(window.indexes.contains(target), "The current map is always in its window")
        if range > 0 {
            check(window.lower == max(0, target - 2), "Rolling windows retain two rear blocks")
            check(window.upper == 100 || distances[window.upper] >= distances[target] + Double(range) * 1000,
                  "The far endpoint reaches the selected route distance")
            if window.upper > target && window.upper < 100 {
                check(distances[window.upper - 1] < distances[target] + Double(range) * 1000,
                      "The window does not unnecessarily prepare beyond the first covering endpoint")
            }
        }
    }
}

var backoff = Policy.Backoff()
for (attempt, delay) in [15.0, 30, 60, 120, 240, 300, 300, 300].enumerated() {
    backoff.fail(10, at: date)
    check(backoff.failures[10]?.retryAt == date.addingTimeInterval(delay), "Block retry delay doubles and caps at five minutes")
    check(!backoff.isEligible(10, at: date.addingTimeInterval(delay - 0.001)), "The deadline is inclusive only when reached")
    check(backoff.isEligible(10, at: date.addingTimeInterval(delay)), "An elapsed block is eligible for retry")
    check(backoff.failures[10]?.attempts == min(6, attempt + 1), "Retry attempts remain bounded")
}
backoff.fail(90, at: date)
backoff.retry(middle.indexes)
check(backoff.failures[10] == nil && backoff.failures[90] != nil, "One-click retry clears only the current window")
backoff.fail(10, at: date)
check(backoff.failures[10]?.retryAt == date.addingTimeInterval(15), "Explicit retry resets the exponential sequence")
backoff.succeed(10)
check(backoff.failures[10] == nil, "Successful work clears prior failure")
check(backoff.failedCount(in: middle.indexes) == 0, "Failures outside the window are not counted")

var available = [Bool](repeating: false, count: distances.count)
var fresh = available, details = available
backoff = Policy.Backoff()
backoff.fail(10, at: date)
var selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                              buildings: false, backoff: backoff, at: date)
check(selection.work?.index == 11 && selection.retryAt == nil, "A failed first block does not hold the healthy next block")
for index in middle.priority where index != 10 {
    available[index] = true; fresh[index] = true; details[index] = true
}
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: false, backoff: backoff, at: date)
check(selection.work == nil && selection.retryAt == date.addingTimeInterval(15), "The worker waits only when every pending block is backing off")
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: false, backoff: backoff, at: date.addingTimeInterval(15))
check(selection.work?.index == 10 && selection.retryAt == nil, "The failed block resumes at its own deadline")
backoff.retry(middle.indexes)
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: false, backoff: backoff, at: date)
check(selection.work?.index == 10, "Manual retry does not wait for an old deadline")

// Available old packets are behind missing maps, but each block's own retry gate still applies.
available[10] = true; fresh[10] = false
available[11] = false; fresh[11] = false
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: true, backoff: backoff, at: date)
check(selection.work?.index == 11 && selection.work?.includeBuildings == false, "A missing healthy base is prepared before updating an old map")
backoff.fail(11, at: date)
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: true, backoff: backoff, at: date)
check(selection.work?.index == 10, "A failed missing map cannot starve another stale but usable map")
backoff.fail(10, at: date.addingTimeInterval(-10))
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: true, backoff: backoff, at: date)
check(selection.work == nil && selection.retryAt == date.addingTimeInterval(5),
      "Multiple failed blocks wait for the earliest individual deadline")

// Buildings must wait for the selected window's fresh bases, never the unselected whole route.
for index in middle.indexes { available[index] = true; fresh[index] = true; details[index] = false }
backoff = Policy.Backoff()
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: true, backoff: backoff, at: date)
check(selection.work?.index == 10 && selection.work?.includeBuildings == true, "Unprepared distant route blocks do not block this window's buildings")
for index in middle.indexes { details[index] = true }
selection = Policy.select(window: middle, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: true, backoff: backoff, at: date)
check(selection.work == nil && selection.retryAt == nil, "A completed window schedules no distant blocks")
let rolling = Policy.window(distances: distances, target: 11, rangeKm: 5)
selection = Policy.select(window: rolling, baseReady: available, freshBase: fresh, freshDetails: details,
                          buildings: true, backoff: backoff, at: date)
check(selection.work?.index == 20 && selection.work?.includeBuildings == false, "Advancing prepares the newly entered forward block")
check(!middle.hasSameCoverage(as: rolling), "Rolling triggers new protection and cache inspection")
check(Policy.window(distances: distances, target: 10, rangeKm: 0).hasSameCoverage(as:
    Policy.window(distances: distances, target: 11, rangeKm: 0)), "Whole-route movement only changes work priority")

print("Offline preparation policy: \(checks) checks passed")
