import Foundation

/// Search generations and a bounded, area-aware result cache. Kept independent of the map SDK
/// so out-of-order callbacks, expired locations and cache eviction can be replayed on a computer.
struct SearchRequestPolicy<Value> {
    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    struct LocationFix {
        let coordinate: Coordinate
        let timestamp: Date
        let accuracy: Double
        let authorized: Bool
    }

    struct CacheKey: Hashable {
        let query: String
        let latitudeCell: Int?
        let longitudeCell: Int?
    }

    struct Ticket: Equatable {
        let id: UUID
        let key: CacheKey
    }

    enum Start {
        case empty
        case cached([Value])
        case request(Ticket)
    }

    private struct Entry {
        let values: [Value]
        let createdAt: Date
        var lastAccess: UInt64
    }

    private var entries: [CacheKey: Entry] = [:]
    private var active: Ticket?
    private var access: UInt64 = 0
    private let ttl: TimeInterval
    private let capacity: Int

    init(ttl: TimeInterval = 5 * 60, capacity: Int = 32) {
        self.ttl = ttl.isFinite ? max(0, ttl) : 5 * 60
        self.capacity = max(1, capacity)
    }

    var cachedCount: Int { entries.count }

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A denied, stale or inaccurate retained CLLocation must not bias a new search.
    /// Approximate but usable positions can still improve nearby results; precise GPS is optional.
    static func nearbyCoordinate(_ fix: LocationFix?, now: Date) -> Coordinate? {
        guard let fix = fix, fix.authorized else { return nil }
        let coordinate = fix.coordinate
        let age = now.timeIntervalSince(fix.timestamp)
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
              age.isFinite, age >= -5, age <= 20,
              fix.accuracy.isFinite, fix.accuracy >= 0, fix.accuracy <= 3_000 else { return nil }
        return coordinate
    }

    static func cacheKey(query: String, nearby: Coordinate?) -> CacheKey {
        // A 0.02 degree cell is about 2 km north/south. Unlocated searches occupy their own key.
        guard let nearby = nearby, nearby.latitude.isFinite, nearby.longitude.isFinite,
              (-90...90).contains(nearby.latitude), (-180...180).contains(nearby.longitude) else {
            return CacheKey(query: normalized(query), latitudeCell: nil, longitudeCell: nil)
        }
        return CacheKey(query: normalized(query),
                        latitudeCell: Int(floor(nearby.latitude / 0.02)),
                        longitudeCell: Int(floor(nearby.longitude / 0.02)))
    }

    mutating func begin(query: String, nearby: Coordinate?, now: Date) -> Start {
        invalidate()
        let key = Self.cacheKey(query: query, nearby: nearby)
        guard !key.query.isEmpty else { return .empty }
        prune(at: now)
        if var entry = entries[key] {
            access &+= 1
            entry.lastAccess = access
            entries[key] = entry
            return .cached(entry.values)
        }
        let ticket = Ticket(id: UUID(), key: key)
        active = ticket
        return .request(ticket)
    }

    /// Success and failure consume the same active ticket; duplicate or old callbacks do nothing.
    mutating func succeed(_ ticket: Ticket, values: [Value], now: Date) -> Bool {
        guard active == ticket else { return false }
        active = nil
        prune(at: now)
        guard now.timeIntervalSinceReferenceDate.isFinite else { return true }
        access &+= 1
        entries[ticket.key] = Entry(values: values, createdAt: now, lastAccess: access)
        while entries.count > capacity {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
        return true
    }

    mutating func fail(_ ticket: Ticket) -> Bool {
        guard active == ticket else { return false }
        active = nil
        return true
    }

    mutating func invalidate() { active = nil }

    mutating func reset() {
        invalidate()
        entries.removeAll()
        access = 0
    }

    private mutating func prune(at now: Date) {
        entries = entries.filter {
            let age = now.timeIntervalSince($0.value.createdAt)
            return age.isFinite && age >= 0 && age < ttl
        }
    }
}
