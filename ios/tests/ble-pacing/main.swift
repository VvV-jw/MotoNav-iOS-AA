import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
var pace = BleWritePacer()
for _ in 0..<BleWritePacer.burst { check(pace.take(now: 0), "Initial bounded burst") }
check(!pace.take(now: 0), "Ready callbacks cannot reset the shared burst budget")
check(!pace.take(now: 0.019), "Navigation pump calls also respect the cooldown")
check(pace.delay(now: 0.019) > 0, "Exhausted budget schedules a later pump")
check(pace.take(now: 0.02), "Queued data continues after the interval")
pace.reset()
check(pace.take(now: 0.021), "Reconnect receives a fresh budget")

// Exercise a large transfer against the real firmware ring capacity and 30-message drain limit,
// with slower 80ms frame processing. Unpaced writes overflow this receiver in one pump call.
pace.reset()
var time = 0.0, drainedAt = 0.0, received = 0, delivered = 0, peak = 0, overflow = false
while delivered < 1000 {
    if time - drainedAt >= 0.08 { delivered += min(30, received); received = max(0, received - 30); drainedAt = time }
    while delivered + received < 1000, pace.take(now: time) {
        received += 1; peak = max(peak, received); overflow = overflow || received > 47
    }
    time += 0.001
    precondition(time < 10, "Pacing must not stall a transfer")
}
check(!overflow, "Map and image writes do not overflow the firmware RX ring")
check(delivered == 1000, "Every fragment reaches the receiver")
check(peak <= 30, "Receiver keeps capacity for navigation commands")
check(time < 4, "Paced thousand-fragment transfer remains usable")
let transferSeconds = time
print("BLE pacing: \(checks) checks passed; peak RX queue \(peak), 1000 fragments \(String(format: "%.2f", transferSeconds))s")

// Slow complete-map frames must not overrun the same 47-message receive ring.
// Exercise the production pacer with the firmware's actual 30-message drain.
for frameMS in [120.0, 200.0, 400.0, 800.0] {
    pace.reset(); pace.observeReceiver(drawMS: frameMS, flushMS: 20)
    var t = 0.0, drain = frameMS / 1000, queued = 0, completed = 0, peakQueue = 0
    while completed < 600 {
        if t >= drain { completed += min(30, queued); queued = max(0, queued - 30); drain += frameMS / 1000 }
        while completed + queued < 600, pace.take(now: t) { queued += 1; peakQueue = max(peakQueue, queued) }
        t += 0.001
        precondition(t < 30, "Slow renderer must keep making transfer progress")
    }
    check(peakQueue <= 30, "Slow-render pacing leaves navigation headroom")
    check(completed == 600, "All slow-render fragments survive")
}
pace.reset(); pace.observeReceiver(drawMS: .nan, flushMS: 20)
for _ in 0..<6 { check(pace.take(now: 0), "Invalid telemetry cannot stall traffic") }
check(!pace.take(now: 0), "Invalid telemetry cannot unbound bursts")
print("Adaptive BLE pacing: \(checks) total checks passed")
