import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let at: Int64 = 10_000
let expires = at + 3_000
guard let left = TrafficSignalPacket(status: 1, dir: 1, wait: 0, show: 0,
                                     remainingMs: 23_000, atMs: at, expiresAtMs: expires),
      let straight = TrafficSignalPacket(status: 4, dir: 4, wait: 2, show: 1,
                                         remainingMs: 34_000, atMs: at, expiresAtMs: expires),
      let right = TrafficSignalPacket(status: -1, dir: 2, wait: 0, show: 0,
                                      remainingMs: 5_000, atMs: at, expiresAtMs: expires) else {
    fatalError("valid packet rejected")
}

expect(left.encode(nowMs: at) == "#TL,1,1,23000,1,0,0,3000", "single wire format")
expect(left.encode(nowMs: at + 123) == "#TL,1,1,22877,1,0,0,2877", "write-time countdown")
expect(left.seconds(nowMs: at + 123) == 23, "ceil seconds")
expect(left.expired(nowMs: at - 1), "future packet must not write")
expect(left.expired(nowMs: at + 400), "400ms write lease")
expect(left.encode(nowMs: expires) == nil, "expired TTL must not write")

guard let batch = TrafficSignalBatchPacket(lights: [left, straight, right], atMs: at) else {
    fatalError("valid batch rejected")
}
expect(batch.encode(nowMs: at) ==
       "#TLS,1,3,1,1,23000,0,0,3000,4,4,34000,2,1,3000,2,-1,5000,0,0,3000",
       "batch wire format")
expect(batch.expired(nowMs: at + 399) == false, "batch remains writable before 400ms")
expect(batch.expired(nowMs: at + 400), "batch write lease")

expect(TrafficSignalPacket(status: -2, dir: 1, wait: 0, show: 0,
                           remainingMs: 1, atMs: at, expiresAtMs: expires) == nil,
       "status range")
expect(TrafficSignalPacket(status: 1, dir: 3, wait: 0, show: 0,
                           remainingMs: 1, atMs: at, expiresAtMs: expires) == nil,
       "direction range")
expect(TrafficSignalPacket(status: 1, dir: 1, wait: 0, show: 0,
                           remainingMs: 999_001, atMs: at, expiresAtMs: expires) == nil,
       "remaining range")
expect(TrafficSignalPacket(status: 1, dir: 1, wait: 0, show: 0,
                           remainingMs: 1, atMs: at, expiresAtMs: at + 3_001) == nil,
       "lease range")
expect(TrafficSignalBatchPacket(lights: [left, left], atMs: at) == nil,
       "duplicate direction")
expect(TrafficSignalBatchPacket(lights: [left], atMs: at + 1) == nil,
       "mixed snapshot time")
expect(TrafficSignalBatchPacket(lights: [], atMs: at) == nil,
       "empty batch")

print("PASS traffic signal wire: Android-compatible #TL/#TLS, write-time ms, expiry and validation")
