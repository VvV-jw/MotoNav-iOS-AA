import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL map-failure-policy after \(checks) checks: \(message)\n".utf8))
        fatalError(message)
    }
    checks += 1
}
let now = Date(timeIntervalSince1970: 784_111_777) // Sun, 06 Nov 1994 08:49:37 GMT
check(MapFailurePolicy.retryAfter("120", now: now) == 120, "Retry-After accepts integer seconds")
check(MapFailurePolicy.retryAfter(" 60 \r\n", now: now) == 60, "Header whitespace is harmless")
check(MapFailurePolicy.retryAfter("0", now: now) == 0, "An explicit zero remains a valid server hint")
check(MapFailurePolicy.retryAfter("Sun, 06 Nov 1994 08:50:37 GMT", now: now) == 60, "HTTP-date is relative to the response time")
check(MapFailurePolicy.retryAfter("Sunday, 06-Nov-94 08:50:37 GMT", now: now) == 60, "The obsolete RFC 850 HTTP-date remains readable")
check(MapFailurePolicy.retryAfter("Sun Nov 6 08:50:37 1994", now: now) == 60, "The obsolete asctime HTTP-date remains readable")
check(MapFailurePolicy.retryAfter("Sun, 06 Nov 1994 08:40:37 GMT", now: now) == 0, "A past date does not create a negative cooldown")
check(MapFailurePolicy.retryAfter(nil, now: now) == nil, "Missing headers use the bounded fallback")
for value in ["", "-1", "+1", "3.5", "1e3", "NaN", "Infinity", "unknown", String(repeating: "9", count: 400)] {
    check(MapFailurePolicy.retryAfter(value, now: now) == nil, "Malformed Retry-After is rejected: \(value.prefix(12))")
}
for status in [429, 503] {
    let explicit = MapFailurePolicy.classify(MapServiceError.http(status: status, retryAfter: 123))
    check(explicit.category == .rateLimited && explicit.action == .cooldown(123), "A service-wide limit respects its Retry-After")
    check(MapFailurePolicy.classify(MapServiceError.http(status: status, retryAfter: nil)).action == .cooldown(60),
          "A missing service hint waits sixty seconds on both platforms")
    check(MapFailurePolicy.classify(MapServiceError.http(status: status, retryAfter: 0)).action == .cooldown(1),
          "A zero service hint cannot create a tight retry loop")
    for invalid in [-1.0, Double.nan, Double.infinity] {
        check(MapFailurePolicy.classify(MapServiceError.http(status: status, retryAfter: invalid)).action == .cooldown(60),
              "Invalid structured hints retain the safe sixty-second fallback")
    }
}
for status in [401, 403] {
    let decision = MapFailurePolicy.classify(MapServiceError.http(status: status, retryAfter: 1))
    check(decision.category == .configuration && decision.action == .pauseConfiguration,
          "An authorization rejection requires configuration correction rather than background retries")
}
check(MapFailurePolicy.classify(MapServiceError.configuration("Missing key")).action == .pauseConfiguration,
      "A typed missing-key failure pauses preparation")
check(MapFailurePolicy.classify(MapServiceError.memoryPressure).action == .pauseMemory, "An OS memory-pressure signal has its own pause")
check(MapFailurePolicy.classify(MapServiceError.timeout).category == .timeout, "A capture timeout stays retryable per block")
check(MapFailurePolicy.classify(MapServiceError.invalidData("Rejected payload")).action == .retryBlock, "Invalid data receives bounded per-block backoff")
for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed] {
    let value = MapFailurePolicy.classify(NSError(domain: NSURLErrorDomain, code: code))
    check(value.category == .network && value.action == .retryBlock, "Network errors do not disable healthy route blocks")
}
check(MapFailurePolicy.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)).category == .timeout,
      "URL loading timeout remains a timeout")
check(MapFailurePolicy.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)).action == .cancel,
      "Cancellation does not count as failure")
for status in [400, 404, 408, 500, 502, 504] {
    check(MapFailurePolicy.classify(MapServiceError.http(status: status, retryAfter: 5)).action == .retryBlock,
          "Other HTTP errors do not create an authorization or service-wide gate")
}
let secret = "do-not-log-this-key"
let unsafe = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
    userInfo: [NSLocalizedDescriptionKey: "https://example.invalid/map?key=\(secret)", NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/?key=\(secret)")!])
check(!MapFailurePolicy.classify(unsafe).message.contains(secret), "Network messages never echo URL credentials")
let unknown = NSError(domain: "unrelated-domain", code: 1002,
    userInfo: [NSLocalizedDescriptionKey: "INVALID_KEY https://example.invalid/?key=\(secret)"])
check(MapFailurePolicy.classify(unknown).category == .unknown, "Neither message text nor a coincident SDK-like integer implies an authorization error")
check(!MapFailurePolicy.classify(unknown).message.contains(secret), "Unknown errors use a safe bounded message")
let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: unsafe])
check(MapFailurePolicy.classify(wrapped).category == .network, "Known underlying failures survive URL/SDK wrapping")
for code in [1001, 1002, 1003, 1008, 1009, 1012, 1013] {
    let error = NSError(domain: "sdk-declared-search-domain", code: code)
    let mapped = MapFailurePolicy.amapSearchFailure(error, expectedDomain: "sdk-declared-search-domain")
    check(mapped.map { MapFailurePolicy.classify($0).action } == .pauseConfiguration,
          "Official AMap search configuration codes apply only to the SDK-declared search domain")
    check(MapFailurePolicy.amapSearchFailure(error, expectedDomain: "different-domain") == nil,
          "A different SDK/map domain cannot reuse search error codes")
}
check(MapFailurePolicy.amapSearchFailure(NSError(domain: "sdk", code: 1102), expectedDomain: "sdk").map {
    MapFailurePolicy.classify($0).category
} == .timeout, "Official search timeout codes are kept retryable")
enum Storage: MapStorageFailure {
    case full, protected, io
    var isStorageBlocked: Bool { self != .io }
}
for error in [Storage.full, Storage.protected] {
    check(MapFailurePolicy.classify(error).action == .pauseStorage, "Both packet/raw cache capacity failures use storage pause semantics")
}
check(MapFailurePolicy.classify(Storage.io).action == .retryBlock, "A generic cache I/O error does not pretend the disk is full")
check(MapFailurePolicy.classify(NSError(domain: NSPOSIXErrorDomain, code: 28)).action == .pauseStorage,
      "Native ENOSPC pauses global preparation")
print("Map failure policy: \(checks) checks passed")
