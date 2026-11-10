import Foundation

enum CallState: Int, Equatable, CaseIterable {
    case inactive = 0
    case ringing = 1
    case dialing = 2
    case active = 3
    case held = 4

    var isInCall: Bool { self != .inactive }
}

/// Only CallKit flags are accepted. Audio interruptions and microphone use do not
/// establish that another app is in a call.
enum CallStateReducer {
    struct Call: Equatable {
        let id: UUID
        let isOutgoing: Bool
        let hasConnected: Bool
        let hasEnded: Bool
        let isOnHold: Bool
    }

    static func state(for calls: [Call]) -> CallState {
        let states = calls.filter { !$0.hasEnded }.map { call -> CallState in
            if !call.hasConnected { return call.isOutgoing ? .dialing : .ringing }
            return call.isOnHold ? .held : .active
        }
        for state in [CallState.ringing, .active, .dialing, .held] {
            if states.contains(state) { return state }
        }
        return .inactive
    }

    /// Read current flags from the live snapshot, rather than resurrecting an
    /// earlier queued delegate event after returning to the foreground.
    static func applying(_ change: Call, to snapshot: [Call]) -> [Call] {
        snapshot.filter { !$0.hasEnded && (!change.hasEnded || $0.id != change.id) }
    }
}

/// Publishes the caller's current snapshot, never a queued call from an old
/// connection. The receiver expires the indicator after 20 seconds.
struct CallDisplaySync {
    static let heartbeatInterval: TimeInterval = 10
    private var lastState: CallState?
    private var lastSent: TimeInterval?

    mutating func reset() {
        lastState = nil
        lastSent = nil
    }

    mutating func command(state: CallState, now: TimeInterval, ready: Bool,
                          supported: Bool, force: Bool = false) -> String? {
        guard ready && supported else { reset(); return nil }
        guard now.isFinite && now >= 0 else { return nil }
        if !force, state == lastState, let lastSent = lastSent,
           now >= lastSent, now - lastSent < Self.heartbeatInterval { return nil }
        lastState = state
        lastSent = now
        return "#CS,\(state.rawValue)"
    }
}
