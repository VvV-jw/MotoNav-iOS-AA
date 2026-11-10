import Foundation

enum SpeechVolumePolicy {
    static let userDefaultsKey = "nav_voice_volume"
    static let defaultVolume = 1.0

    static func normalized(_ value: Double?) -> Double {
        guard let value = value, value.isFinite else { return defaultVolume }
        return min(1, max(0, value))
    }

    static func load(_ defaults: UserDefaults = .standard) -> Double {
        normalized((defaults.object(forKey: userDefaultsKey) as? NSNumber)?.doubleValue)
    }
}

/// Tokens make late cancellation callbacks harmless after an interrupted queue
/// is cleared and the next navigation instruction has already started.
struct SpeechPlaybackState {
    private(set) var blockedByCall = false
    private var counter: UInt64 = 0
    private var pending: Set<UInt64> = []
    var isEmpty: Bool { pending.isEmpty }

    mutating func begin() -> UInt64? {
        guard !blockedByCall else { return nil }
        repeat { counter &+= 1 } while pending.contains(counter)
        pending.insert(counter)
        return counter
    }

    /// True only when this completion finishes the current queue.
    mutating func finish(_ token: UInt64) -> Bool {
        pending.remove(token) != nil && pending.isEmpty
    }

    mutating func clear() { pending.removeAll() }

    /// True when entering a call requires the synthesizer to stop.
    mutating func updateCallState(_ state: CallState) -> Bool {
        let shouldStop = state.isInCall && !blockedByCall
        blockedByCall = state.isInCall
        if blockedByCall { clear() }
        return shouldStop
    }
}
