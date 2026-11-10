import Foundation

var checks = 0
func check(_ truth: Bool, _ reason: String) { precondition(truth, reason); checks += 1 }
let primary = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let secondary = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
func call(_ state: CallState, id: UUID = primary) -> CallStateReducer.Call {
    CallStateReducer.Call(id: id, isOutgoing: state == .dialing,
                          hasConnected: state == .active || state == .held,
                          hasEnded: state == .inactive, isOnHold: state == .held)
}
check(CallStateReducer.state(for: []) == .inactive, "empty live snapshot clears old call")
for state in CallState.allCases {
    check(state.rawValue >= 0 && state.rawValue <= 4, "bounded wire state")
    check(state.isInCall == (state != .inactive), "only inactive clears call icon")
    check(CallStateReducer.state(for: [call(state)]) == state, "single call flags reduce to state")
}
let priority: [CallState] = [.ringing, .active, .dialing, .held, .inactive]
for lhs in CallState.allCases {
    for rhs in CallState.allCases {
        let expected = priority.first { $0 == lhs || $0 == rhs }!
        let first = call(lhs), second = call(rhs, id: secondary)
        check(CallStateReducer.state(for: [first, second]) == expected, "multiple call priority")
        check(CallStateReducer.state(for: [second, first]) == expected, "call order cannot change icon")
    }
}
let ended = call(.inactive)
let staleActive = [call(.active)]
check(CallStateReducer.applying(ended, to: staleActive).isEmpty, "ended delegate beats lagging live array")
let ringing = call(.ringing)
let replaced = CallStateReducer.applying(ringing, to: staleActive)
check(replaced == staleActive, "live connected flags beat queued ringing callback")
let stillActive = CallStateReducer.applying(ended, to: staleActive + [call(.active, id: secondary)])
check(CallStateReducer.state(for: stillActive) == .active, "ending one call preserves second call")
check(CallStateReducer.applying(call(.active), to: [ended]).isEmpty, "late active callback cannot revive an ended snapshot")
check(CallStateReducer.applying(call(.active), to: []).isEmpty, "late active callback cannot revive an empty foreground snapshot")

var display = CallDisplaySync()
check(display.command(state: .active, now: 0, ready: false, supported: true) == nil, "offline active snapshot is not queued")
check(display.command(state: .inactive, now: 1, ready: true, supported: false) == nil, "wait for firmware capability")
check(display.command(state: .inactive, now: 2, ready: true, supported: true) == "#CS,0", "late capability sends current inactive state")
check(display.command(state: .inactive, now: 11.99, ready: true, supported: true) == nil, "heartbeat bounded below ten seconds")
check(display.command(state: .inactive, now: 12, ready: true, supported: true) == "#CS,0", "ten second heartbeat keeps twenty second receiver fresh")
check(display.command(state: .active, now: 12.1, ready: true, supported: true) == "#CS,3", "state changes publish immediately")
check(display.command(state: .ringing, now: 12.2, ready: true, supported: true) == "#CS,1", "second incoming call is not throttled")
check(display.command(state: .dialing, now: 12.3, ready: true, supported: true) == "#CS,2", "outgoing call has distinct state")
check(display.command(state: .held, now: 12.4, ready: true, supported: true) == "#CS,4", "held call has distinct state")
check(display.command(state: .held, now: 12.4, ready: true, supported: true, force: true) == "#CS,4", "forced snapshot resends immediately")
check(display.command(state: .held, now: 2, ready: true, supported: true) == "#CS,4", "monotonic clock reset cannot starve heartbeat")
check(display.command(state: .active, now: .nan, ready: true, supported: true) == nil, "reject NaN heartbeat time")
check(display.command(state: .active, now: .infinity, ready: true, supported: true) == nil, "reject infinite heartbeat time")
check(display.command(state: .active, now: -1, ready: true, supported: true) == nil, "reject negative uptime")
check(display.command(state: .held, now: 3, ready: true, supported: true) == nil, "invalid clocks do not disturb prior heartbeat")
check(display.command(state: .active, now: 3, ready: false, supported: true) == nil, "disconnect forgets prior call heartbeat")
check(display.command(state: .inactive, now: 3.1, ready: true, supported: true) == "#CS,0", "reconnect cannot resurrect earlier active call")
_ = display.command(state: .active, now: 4, ready: true, supported: true)
display.reset()
check(display.command(state: .inactive, now: 4.1, ready: true, supported: true) == "#CS,0", "explicit reset sends only fresh caller snapshot")
check(display.command(state: .active, now: 5, ready: true, supported: false) == nil, "capability loss discards active state")
check(display.command(state: .inactive, now: 6, ready: true, supported: true) == "#CS,0", "recovered capability cannot replay discarded active call")

check(SpeechVolumePolicy.normalized(nil) == 1, "old installations keep full navigation gain")
check(SpeechVolumePolicy.normalized(.nan) == 1, "NaN cannot reach the synthesizer")
check(SpeechVolumePolicy.normalized(.infinity) == 1, "infinite gain repaired")
check(SpeechVolumePolicy.normalized(-.infinity) == 1, "negative infinite gain repaired")
check(SpeechVolumePolicy.normalized(-0.01) == 0, "negative gain clamps to silence")
check(SpeechVolumePolicy.normalized(1.01) == 1, "gain cannot exceed system output")
check(SpeechVolumePolicy.normalized(0) == 0, "explicit zero is preserved")
check(SpeechVolumePolicy.normalized(0.35) == 0.35, "navigation gain remains independent")
let suiteName = "MotoNavCallAudioTests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
check(SpeechVolumePolicy.load(defaults) == 1, "missing persisted gain preserves existing volume")
defaults.set(0.2, forKey: SpeechVolumePolicy.userDefaultsKey)
check(SpeechVolumePolicy.load(defaults) == 0.2, "stored navigation gain loaded")
defaults.removeObject(forKey: SpeechVolumePolicy.userDefaultsKey)

var speech = SpeechPlaybackState()
let first = speech.begin()!, queued = speech.begin()!
check(!speech.isEmpty, "navigation queue records prompts")
check(!speech.finish(first), "first finish cannot release a queued prompt")
check(speech.finish(queued) && speech.isEmpty, "last prompt releases audio session")
check(!speech.finish(queued), "duplicate completion cannot release again")
let old = speech.begin()!
let oldQueued = speech.begin()!
check(speech.updateCallState(.ringing), "incoming call stops current navigation")
check(speech.blockedByCall && speech.isEmpty, "call clears queued old instructions")
check(speech.begin() == nil, "call blocks new instruction instead of accumulating it")
check(!speech.updateCallState(.active), "answering same call does not repeatedly stop other sessions")
check(!speech.updateCallState(.held) && speech.begin() == nil, "held call keeps navigation suppressed")
check(!speech.updateCallState(.inactive) && !speech.blockedByCall, "call end permits future instructions")
let future = speech.begin()!
check(!speech.finish(old) && !speech.isEmpty, "late pre-call cancel cannot finish new prompt")
check(!speech.finish(oldQueued) && !speech.isEmpty, "late queued pre-call cancel cannot release new prompt")
check(speech.finish(future), "post-call instruction finishes normally")
let mutedPrompt = speech.begin()!
speech.clear()
let unmutedPrompt = speech.begin()!
check(!speech.finish(mutedPrompt) && !speech.isEmpty, "late mute cancellation cannot finish a later prompt")
check(speech.finish(unmutedPrompt), "queue cleared by explicit stop can speak normally later")
for state in [CallState.dialing, .active, .held, .ringing] {
    speech.clear()
    _ = speech.updateCallState(.inactive)
    _ = speech.begin()
    check(speech.updateCallState(state) && speech.isEmpty && speech.begin() == nil, "all known call states suppress navigation")
}
print("Call state and navigation audio: \(checks) checks passed")
