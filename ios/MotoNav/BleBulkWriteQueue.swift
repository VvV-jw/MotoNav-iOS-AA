import Foundation

/// Keep one ATT write in flight; replacing a map must not resurrect its obsolete fragments.
struct BleBulkWriteQueue {
    struct Part { let type: Int, id: Int, data: Data; var attempts = 0 }
    enum Result: Equatable { case sent, retry, obsolete, failed }
    private var parts: [Part] = []
    private var latest: [Int: Int] = [:]
    private var acknowledged: [Int: Int] = [:]
    private(set) var inFlight: Part?
    var hasData: Bool { inFlight != nil || !parts.isEmpty }
    var canStart: Bool { inFlight == nil && !parts.isEmpty }
    var queuedCount: Int { parts.count }
    var peek: Part? { canStart ? parts.first : nil }
    func contains(type: Int, id: Int) -> Bool {
        (inFlight?.type == type && inFlight?.id == id) || parts.contains { $0.type == type && $0.id == id }
    }
    func payloadRemaining(type: Int, id: Int) -> Int {
        let queued = parts.lazy.filter { $0.type == type && $0.id == id }.reduce(0) { $0 + max(0, $1.data.count - 15) }
        return queued + (inFlight.map { $0.type == type && $0.id == id ? max(0, $0.data.count - 15) : 0 } ?? 0)
    }
    mutating func replace(type: Int, id: Int, packets: [Data], prioritize: Bool = false) {
        parts.removeAll { $0.type == type }
        latest[type] = id; acknowledged.removeValue(forKey: type)
        let incoming = packets.map { Part(type: type, id: id, data: $0) }
        if prioritize { parts.insert(contentsOf: incoming, at: 0) }
        else { parts.append(contentsOf: incoming) }
    }
    mutating func next() -> Part? {
        guard canStart else { return nil }
        var part = parts.removeFirst(); part.attempts += 1; inFlight = part
        return part
    }
    mutating func complete(success: Bool) -> Result {
        guard let part = inFlight else { return .obsolete }
        inFlight = nil
        if success || acknowledged[part.type] == part.id { return .sent }
        guard latest[part.type] == part.id else { return .obsolete }
        if part.attempts < 3 { parts.insert(part, at: 0); return .retry }
        parts.removeAll { $0.type == part.type && $0.id == part.id }
        return .failed
    }
    mutating func acknowledge(type: Int, id: Int) {
        acknowledged[type] = id
        parts.removeAll { $0.type == type && $0.id == id }
        // An application K can arrive before the ATT callback; still wait for that callback.
    }
    /// Leave the outstanding ATT callback paired with its original write. A late failure
    /// after a style change must never put the cancelled map back into the queue.
    mutating func cancel(types: Set<Int>) {
        parts.removeAll { types.contains($0.type) }
        for type in types { latest.removeValue(forKey: type); acknowledged.removeValue(forKey: type) }
    }
    mutating func reset() { parts.removeAll(); latest.removeAll(); acknowledged.removeAll(); inFlight = nil }
}

enum BleOutboundPriority {
    enum Choice: Equatable { case command, bulk, image, idle }
    static func choose(commandReady: Bool, bulkReady: Bool, bulkPending: Bool, imageReady: Bool, favorBulk: Bool = false) -> Choice {
        if commandReady && !(favorBulk && bulkReady) { return .command }
        if bulkReady { return .bulk }
        if !bulkPending && imageReady { return .image }
        return .idle
    }
}

/// Bound outstanding commands without paying an ATT round trip for every map fragment.
/// First/last fragments and failed retries always validate the transport with a response.
struct BleBulkBarrier {
    private var commands = 0
    func requiresResponse(seq: Int, parts: Int, retry: Bool) -> Bool {
        seq == 0 || seq == parts - 1 || retry || commands >= 4
    }
    mutating func needsResponse(seq: Int, parts: Int, retry: Bool, commandReady: Bool) -> Bool {
        if requiresResponse(seq: seq, parts: parts, retry: retry) { return true }
        commands += 1
        return false
    }
    static func canStart(response: Bool, canWithout: Bool) -> Bool { response || canWithout }
    mutating func reset() { commands = 0 }
}

/// A lost K is recovered by repeating only the tail, without treating an ATT
/// completion as a decoded map. The normal same-ID whole-packet retry remains.
struct BleMapReceipt {
    struct Identity: Equatable { let type: Int, id: Int }
    struct Pending {
        let identity: Identity, tail: Data
        var wireDone: Double?
        var probes = 0
    }
    private(set) var current: Pending?
    mutating func begin(type: Int, id: Int, tail: Data) {
        current = Pending(identity: .init(type: type, id: id), tail: tail)
    }
    mutating func wireFinished(type: Int, id: Int, at now: Double) -> Bool {
        guard var pending = current, pending.identity == Identity(type: type, id: id), pending.wireDone == nil else { return false }
        pending.wireDone = now; current = pending
        return true
    }
    func blocks(type: Int, id: Int) -> Bool { current?.identity == Identity(type: type, id: id) }
    var waiting: Bool { current?.wireDone != nil }
    mutating func probe(now: Double) -> Pending? {
        guard var pending = current, let done = pending.wireDone,
              pending.probes < 2, now - done >= 0.3 * Double(pending.probes + 1), now - done < 2 else { return nil }
        pending.probes += 1; current = pending
        return pending
    }
    mutating func expire(now: Double) -> Identity? {
        guard let pending = current, let done = pending.wireDone,
              now - done >= (pending.identity.type == 3 ? 12 : 2) else { return nil }
        current = nil
        return pending.identity
    }
    mutating func acknowledge(type: Int, id: Int) {
        if blocks(type: type, id: id) { current = nil }
    }
    mutating func reset() { current = nil }
}

/// Samples bytes actually put on the wire, including legacy conversion and
/// compression. A duplicate acknowledged before its tail supplies no rate.
struct BleMapWireMeter {
    private var transfer: (identity: BleMapReceipt.Identity, bytes: Int, at: Double, tailIssued: Bool)?
    private(set) var rate: Double?
    func tailWasIssued(type: Int, id: Int) -> Bool {
        transfer?.identity == BleMapReceipt.Identity(type: type, id: id) && transfer?.tailIssued == true
    }
    mutating func begin(type: Int, id: Int, bytes: Int, at now: Double) {
        transfer = (.init(type: type, id: id), bytes, now, false)
    }
    mutating func tailIssued(type: Int, id: Int) {
        if transfer?.identity == BleMapReceipt.Identity(type: type, id: id) { transfer?.tailIssued = true }
    }
    mutating func finish(type: Int, id: Int, at now: Double) -> (bytes: Int, seconds: Double)? {
        guard let pending = transfer, pending.identity == BleMapReceipt.Identity(type: type, id: id) else { return nil }
        transfer = nil
        guard pending.tailIssued, now > pending.at else { return nil }
        let seconds = now - pending.at, sample = Double(pending.bytes) / seconds
        rate = rate.map { $0 * 0.65 + sample * 0.35 } ?? sample
        return (pending.bytes, seconds)
    }
    mutating func cancel() { transfer = nil }
    mutating func reset() { transfer = nil; rate = nil }
}
