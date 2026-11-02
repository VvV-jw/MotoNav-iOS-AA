import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
let payloads = [Data([1]), Data([2]), Data([3])]
var writer = BleBulkWriteQueue()
writer.replace(type: 3, id: 1, packets: payloads)
let first = writer.next()!
check(first.data == payloads[0] && writer.next() == nil, "Only one ATT write may be in flight")
check(writer.complete(success: false) == .retry, "Failed fragment retries before later fragments")
check(writer.next()?.data == first.data, "Retry preserves exact bytes")
check(writer.complete(success: true) == .sent, "ATT response releases the next fragment")
check(writer.next()?.data == payloads[1], "No fragment skipped after recovery")
writer.replace(type: 3, id: 2, packets: [Data([9])])
check(writer.complete(success: false) == .obsolete, "Late failure cannot resurrect superseded map")
check(writer.next()?.id == 2, "Replacement begins after outstanding callback")
writer.acknowledge(type: 3, id: 2)
check(writer.hasData && !writer.canStart, "Early application K still waits for outstanding ATT callback")
check(writer.complete(success: false) == .sent && !writer.hasData, "Application acknowledgement prevents unnecessary retransmission")

writer.replace(type: 3, id: 3, packets: payloads)
writer.replace(type: 2, id: 8, packets: [Data([7])])
for attempt in 1...3 {
    check(writer.next()?.attempts == attempt, "ATT retries remain bounded")
    _ = writer.complete(success: false)
}
check(writer.next()?.type == 2, "Permanent map error keeps independent route transfer")
_ = writer.complete(success: true)
check(!writer.hasData, "Failed map queue empties so application can retry complete map")
writer.replace(type: 3, id: 4, packets: payloads)
_ = writer.next()
writer.replace(type: 3, id: 5, packets: [Data([8])])
writer.acknowledge(type: 3, id: 4)
_ = writer.complete(success: true)
check(writer.next()?.id == 5, "Old K cannot clear a newer map")
writer.reset()
check(!writer.hasData && writer.inFlight == nil, "Disconnect clears outstanding writes")

// Style changes can cross packet types while a previous ATT write is still waiting.
writer.replace(type: 3, id: 21, packets: payloads)
_ = writer.next()
writer.replace(type: 2, id: 22, packets: [Data([7])])
writer.cancel(types: [1, 3])
writer.replace(type: 1, id: 23, packets: [Data([8])])
check(writer.complete(success: false) == .obsolete, "A cancelled raster cannot return after switching to GTA vectors")
check(writer.next()?.type == 2, "Style cancellation preserves the navigation route")
_ = writer.complete(success: true)
check(writer.next()?.id == 23, "The new style starts after the outstanding callback")
_ = writer.complete(success: true)
check(!writer.hasData, "No old-style fragments remain")

// Continuous decorative images and 50 position/turn commands per second must not starve a map.
// Each ATT response takes 35ms; commands can be served while awaiting the response.
writer.replace(type: 3, id: 6, packets: (0..<60).map { Data([UInt8($0)]) })
var pace = BleWritePacer(), time = 0.0, responseAt: Double?, nextCommand = 0.0
var commandQueued = false, commands = 0, delivered: [UInt8] = [], imageWrites = 0
while writer.hasData {
    if time >= nextCommand { commandQueued = true; nextCommand += 0.02 }
    if let deadline = responseAt, time >= deadline {
        delivered.append(writer.inFlight!.data[0]); _ = writer.complete(success: true); responseAt = nil
    }
    let choice = BleOutboundPriority.choose(commandReady: commandQueued, bulkReady: writer.canStart,
        bulkPending: writer.hasData, imageReady: true)
    if choice != .idle, pace.take(now: time) {
        switch choice {
        case .command: commandQueued = false; commands += 1
        case .bulk: _ = writer.next(); responseAt = time + 0.035
        case .image: imageWrites += 1
        case .idle: break
        }
    }
    time += 0.001
    precondition(time < 4, "Map deadline missed")
}
check(delivered == Array(UInt8(0)..<UInt8(60)), "Every fragment delivered in order despite continuous image traffic")
check(commands > 100 && !commandQueued, "Position and turn commands remain live during ATT transfer")
check(time < 3, "60-fragment map finishes within viewport handoff time")
check(imageWrites <= 1, "Decorative images yield during map transfer")

// Device measurements show ~100ms ATT round trips. Batch four commands between barriers
// so a 60-fragment map still arrives before the previous viewport expires at highway speed.
writer.reset(); writer.replace(type: 3, id: 7, packets: (0..<60).map { Data([UInt8($0)]) })
pace.reset(); time = 0; responseAt = nil; nextCommand = 0; commandQueued = false
delivered = []; commands = 0
var barrier = BleBulkBarrier(), outstanding = 0, peakOutstanding = 0
while writer.hasData {
    if time >= nextCommand { commandQueued = true; nextCommand += 0.02 }
    if let deadline = responseAt, time >= deadline {
        delivered.append(writer.inFlight!.data[0]); _ = writer.complete(success: true)
        barrier.reset(); responseAt = nil; outstanding = 0
    }
    let choice = BleOutboundPriority.choose(commandReady: commandQueued, bulkReady: writer.canStart,
        bulkPending: writer.hasData, imageReady: true)
    if choice != .idle, pace.take(now: time) {
        switch choice {
        case .command: commandQueued = false; commands += 1
        case .bulk:
            let part = writer.next()!, seq = Int(part.data[0])
            let respond = barrier.needsResponse(seq: seq, parts: 60, retry: false, commandReady: true)
            outstanding += 1; peakOutstanding = max(peakOutstanding, outstanding)
            if respond { responseAt = time + 0.1 }
            else { delivered.append(part.data[0]); _ = writer.complete(success: true) }
        case .image, .idle: break
        }
    }
    time += 0.001; precondition(time < 4, "Batched map misses deadline")
}
check(delivered == Array(UInt8(0)..<UInt8(60)), "Batched fragments preserve order and content")
check(peakOutstanding <= 5 && time < 2, "Realistic 100ms round trips keep map under two seconds with bounded bursts")
check(commands > 50, "Navigation remains responsive during confirmed batches")
barrier.reset()
check(barrier.needsResponse(seq: 0, parts: 60, retry: false, commandReady: true), "Validate first fragment before command burst")
check(barrier.needsResponse(seq: 59, parts: 60, retry: false, commandReady: true), "Last fragment waits for actual transport response")
check(barrier.needsResponse(seq: 5, parts: 60, retry: true, commandReady: true), "Failed barrier retry cannot silently become unconfirmed")
check(!barrier.needsResponse(seq: 5, parts: 60, retry: false, commandReady: false), "Host backpressure waits without inventing an ATT barrier")
check(!BleBulkBarrier.canStart(response: false, canWithout: false), "Unconfirmed writes must wait for host readiness")
check(BleBulkBarrier.canStart(response: true, canWithout: false), "A required ATT barrier may start independently")

writer.reset()
writer.replace(type: 3, id: 20, packets: payloads)
_ = writer.next()
writer.replace(type: 2, id: 21, packets: [Data([7])], prioritize: true)
_ = writer.complete(success: true)
check(writer.next()?.type == 2, "A new route takes precedence after the outstanding map fragment")
check(BleOutboundPriority.choose(commandReady: true, bulkReady: true, bulkPending: true, imageReady: false, favorBulk: true) == .bulk,
      "Continuous positions give the map a bounded turn")

for type in [1, 3] {
    var receipt = BleMapReceipt()
    receipt.begin(type: type, id: 9, tail: Data([42]))
    check(receipt.probe(now: 100) == nil && receipt.expire(now: 100) == nil, "No probe clock runs before the true last completion")
    check(!receipt.wireFinished(type: type == 1 ? 3 : 1, id: 9, at: 1), "Same ID in a different packet type cannot finish this map")
    check(receipt.wireFinished(type: type, id: 9, at: 1), "True last completion starts the receipt window")
    check(receipt.probe(now: 1.29) == nil, "The first probe waits at least 0.3 seconds")
    check(receipt.probe(now: 1.3)?.probes == 1, "First tail probe")
    check(receipt.probe(now: 1.59) == nil, "The second probe waits until 0.6 seconds")
    check(receipt.probe(now: 1.6)?.probes == 2, "Second tail probe")
    check(receipt.probe(now: 1.9) == nil && receipt.blocks(type: type, id: 9), "Probes neither repeat unboundedly nor invent K")
    let expiry = type == 3 ? 13.0 : 3.0
    check(receipt.expire(now: expiry - 0.01) == nil && receipt.expire(now: expiry)?.id == 9,
          "Type-specific processing grace releases only a same-ID whole-map retry")
    receipt.begin(type: type, id: 10, tail: Data([1]))
    receipt.acknowledge(type: type, id: 9)
    check(receipt.blocks(type: type, id: 10), "A late old K cannot release a newer packet")
    receipt.reset()
    check(receipt.current == nil, "Disconnect cancels tail recovery")
}
var meter = BleMapWireMeter()
meter.begin(type: 3, id: 1, bytes: 1200, at: 0)
check(meter.finish(type: 3, id: 1, at: 1) == nil, "An early duplicate acknowledgement cannot measure the whole packet")
meter.begin(type: 3, id: 2, bytes: 800, at: 2)
meter.tailIssued(type: 3, id: 2)
check(meter.finish(type: 3, id: 2, at: 4)?.bytes == 800 && meter.rate == 400, "Rate uses actual encoded wire payload bytes")
print("BLE bulk: \(checks) checks passed; map delivery \(String(format: "%.2f", time))s, \(commands) navigation commands")
