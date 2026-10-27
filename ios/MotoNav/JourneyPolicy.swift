import Foundation

/// Only a user's ordered stops belong to an itinerary. Route shape samples and
/// provider IDs deliberately have no representation here.
struct JourneyPoint: Codable, Equatable {
    var name: String
    var lat: Double
    var lng: Double
    var isValid: Bool {
        lat.isFinite && lng.isFinite && abs(lat) <= 90 && abs(lng) <= 180
            && name.count <= 100 && name.utf8.count <= 400
    }
}

enum JourneyMode: String, Codable, CaseIterable {
    case drive, motorcycle, bicycle
    var title: String { self == .drive ? "驾车" : self == .motorcycle ? "摩托车" : "自行车" }
    // The current riding search SDK accepts origin and destination only.
    var maximumVias: Int { self == .bicycle ? 0 : 3 }
}

struct SavedJourney: Codable, Equatable, Identifiable {
    var version = 1
    var id: UUID = UUID()
    var name: String
    var mode: JourneyMode
    var destination: JourneyPoint
    var vias: [JourneyPoint]
    var avoidHighway: Bool
    var createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var isValid: Bool {
        version == 1 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 80 && name.utf8.count <= 320 && destination.isValid
            && vias.count <= mode.maximumVias && vias.allSatisfy(\.isValid)
            && createdAtMs > 0
    }
}

/// Editing is local until Apply. Cancelling neither mutates the request nor
/// consumes an extra route query; each Apply advances the callback owner.
struct JourneyDraft<Point> {
    private(set) var original: [Point]
    private(set) var points: [Point]
    init(_ points: [Point]) { original = points; self.points = points }
    mutating func remove(_ index: Int) { if points.indices.contains(index) { points.remove(at: index) } }
    mutating func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard points.indices.contains(index), points.indices.contains(target) else { return }
        points.swapAt(index, target)
    }
    mutating func append(_ point: Point, limit: Int) { if points.count < limit { points.append(point) } }
    mutating func cancel() { points = original }
}

/// A query owns both a session and a stop cursor. A newer edit, a passed stop,
/// stop/start or a stale/moved phone fix rejects its result before installation.
final class JourneyTransaction {
    struct Ticket: Equatable {
        let generation: UInt64
        let owner: UUID
        let cursor: Int
    }
    private var generation: UInt64 = 0
    func invalidate() { generation &+= 1 }
    func begin(owner: UUID, cursor: Int) -> Ticket {
        invalidate(); return Ticket(generation: generation, owner: owner, cursor: cursor)
    }
    func accepts(_ ticket: Ticket, owner: UUID, cursor: Int, running: Bool,
                 freshFix: Bool, movedMetres: Double) -> Bool {
        ticket.generation == generation && ticket.owner == owner && ticket.cursor == cursor && running
            && freshFix && movedMetres.isFinite && movedMetres >= 0 && movedMetres <= 100
    }
    func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation }
}

enum JourneyReplacement {
    /// The old route and its ordered stops remain one coherent snapshot until
    /// successful calculation AND all ownership checks have passed.
    @discardableResult static func apply<Candidate>(_ result: Result<Candidate, Error>,
        canCommit: () -> Bool, commit: (Candidate) -> Void) -> Bool {
        guard case .success(let candidate) = result, canCommit() else { return false }
        commit(candidate)
        return true
    }
}

/// Capture when a confirmation is presented, before the rider can naturally
/// pass a stop or a replacement route/session can become current.
struct JourneySkipIntent: Equatable {
    let session: UUID
    let route: UUID
    let cursor: Int
}

enum JourneyConfirmation {
    static func matches<Owner: Equatable>(_ expected: Owner?, current: Owner?, active: Bool) -> Bool {
        active && expected != nil && expected == current
    }
}
