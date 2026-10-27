import Foundation

/// Origin intent travels with a candidate independently of the coordinate sampled
/// for one query. A device fix must never turn into a manually selected place.
enum RouteOriginSource: String {
    case currentLocation, selectedPlace
}

struct RouteOriginSelection<Point> {
    var selectedPlace: Point?
    init(selectedPlace: Point? = nil) { self.selectedPlace = selectedPlace }
    init(source: RouteOriginSource, plannedStart: Point) {
        selectedPlace = source == .selectedPlace ? plannedStart : nil
    }
    var source: RouteOriginSource { selectedPlace == nil ? .currentLocation : .selectedPlace }
    func resolve(current: () -> Point?) -> Point? { selectedPlace ?? current() }
}

/// Snapshot taken on the main queue immediately before installing a candidate.
/// Recovery may finish its own query; ordinary imports may not interrupt it.
struct RouteSessionAvailability {
    var independentNavigation = false
    var driveNavigation = false
    var cruising = false
    var drivePlanning = false
    var recovering = false
    var independentPlanning = false

    func canInstallCandidate(finishingRecovery: Bool = false) -> Bool {
        !independentNavigation && !driveNavigation && !cruising && !drivePlanning && !independentPlanning
            && (!recovering || finishingRecovery)
    }
}

enum RouteCandidateCommit {
    /// Persistence is part of accepting a candidate, never a side effect of trying
    /// one. A rejected session or engine release leaves the previous trip intact.
    @discardableResult static func install(session: RouteSessionAvailability, finishingRecovery: Bool = false,
                                           candidate: () -> Bool, persist: () -> Void) -> Bool {
        guard session.canInstallCandidate(finishingRecovery: finishingRecovery), candidate() else { return false }
        persist()
        return true
    }
}

/// Shared by SDK, independent and recovery planning. Even a trip which starts AND
/// stops before an older network reply arrives must invalidate that reply.
final class RoutePlanningGeneration {
    static let shared = RoutePlanningGeneration()
    struct Ticket: Equatable { fileprivate let generation: UInt64 }
    private var generation: UInt64 = 0
    private(set) var isBusy = false
    func invalidate() { generation &+= 1; isBusy = false }
    func begin() -> Ticket { invalidate(); isBusy = true; return Ticket(generation: generation) }
    func accepts(_ ticket: Ticket) -> Bool { ticket.generation == generation }
    @discardableResult func finish(_ ticket: Ticket) -> Bool {
        guard accepts(ticket) else { return false }
        isBusy = false
        return true
    }
    func cancel(_ ticket: Ticket) {
        guard accepts(ticket) else { return }
        invalidate()
    }
}

/// A sheet holds an exact request owner while editing. New imports or candidates
/// invalidate the shared generation, so an older sheet cannot apply to them.
final class RouteDraftLease {
    private let generations: RoutePlanningGeneration
    private var owner: RoutePlanningGeneration.Ticket?
    init(generations: RoutePlanningGeneration = .shared) { self.generations = generations }
    func begin() -> RoutePlanningGeneration.Ticket {
        let ticket = generations.begin(); owner = ticket; return ticket
    }
    func owns(_ ticket: RoutePlanningGeneration.Ticket) -> Bool { owner == ticket }
    @discardableResult func apply(_ ticket: RoutePlanningGeneration.Ticket, commit: () -> Void) -> Bool {
        guard owner == ticket, generations.finish(ticket) else { return false }
        owner = nil; commit(); return true
    }
    @discardableResult func cancel(_ ticket: RoutePlanningGeneration.Ticket) -> Bool {
        guard owner == ticket else { return false }
        owner = nil; generations.cancel(ticket); return true
    }
}
