import Foundation
import AVFoundation

var checks = 0
func check(_ truth: Bool, _ reason: String) { precondition(truth, reason); checks += 1 }
func drain(_ seconds: TimeInterval = 0.03) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01)))
    }
}

let defaults = UserDefaults.standard
let keys = [SpeechVolumePolicy.userDefaultsKey, "voice_id", "voice_rate", "voice_pitch"]
let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
defer {
    for key in keys {
        if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
for key in keys { defaults.removeObject(forKey: key) }

let speech = Speech()
let synth = AVSpeechSynthesizer.latest!
let session = AVAudioSession.sharedInstance()

defaults.set(0.35, forKey: SpeechVolumePolicy.userDefaultsKey)
speech.speak(" first ")
let first = synth.submitted.last!
check(first.speechString == "first", "actual adapter trims navigation text")
check(abs(first.volume - 0.35) < 0.0001, "actual utterance receives independent navigation gain")
check(session.isActive && speech.isSpeaking, "actual adapter activates only its speech session")
speech.speak("second queued prompt")
let queued = synth.submitted.last!
check(synth.submitted.count == 2, "adapter queues consecutive prompts")

speech.updateCallState(.ringing)
check(synth.stops == 1, "incoming call stops the real adapter's synthesizer")
check(!session.isActive && !speech.isSpeaking, "incoming call releases the app audio session")
let callCount = synth.submitted.count
speech.speak("discard this stale route instruction")
speech.updateCallState(.active)
speech.speak("also discard while speaking on phone")
check(synth.submitted.count == callCount && synth.stops == 1, "call blocks new prompts without repeated synth stops")

speech.updateCallState(.inactive)
speech.speak("new instruction after the call")
let future = synth.submitted.last!
check(session.isActive && speech.isSpeaking, "new post-call instruction may speak")
synth.emitCancel(first)
synth.emitCancel(queued)
drain()
check(session.isActive && speech.isSpeaking, "two late pre-call cancellations cannot finish new speech")
check(session.activeChanges.last == true, "late cancellations cannot release the new session")
synth.emitFinish(future)
drain()
check(session.isActive, "post-speech duck release remains delayed")
drain(0.5)
check(!session.isActive && !speech.isSpeaking, "last current utterance releases session after the delay")

let categoryCount = session.categoryCalls
let zeroCount = synth.submitted.count
defaults.set(0, forKey: SpeechVolumePolicy.userDefaultsKey)
speech.speak("silent gain must not duck music")
check(synth.submitted.count == zeroCount && session.categoryCalls == categoryCount, "gain zero neither speaks nor activates audio")
defaults.set(1, forKey: SpeechVolumePolicy.userDefaultsKey)
Settings.shared.voiceMuted = true
speech.speak("muted")
check(synth.submitted.count == zeroCount, "mute prevents synthesizer submission")
Settings.shared.voiceMuted = false
speech.speak("before explicit stop")
let stopped = synth.submitted.last!
speech.stopNow()
check(!session.isActive && !speech.isSpeaking, "explicit mute stop immediately releases session")
speech.speak("new prompt after explicit stop")
let current = synth.submitted.last!
synth.emitCancel(stopped)
drain()
check(session.isActive && speech.isSpeaking, "late explicit-stop cancellation cannot finish later speech")
synth.emitFinish(current)
drain(0.5)
check(!session.isActive && !speech.isSpeaking, "later speech completes normally")

session.failActivation = true
let failureCount = synth.submitted.count
speech.speak("audio session owned by another app")
check(synth.submitted.count == failureCount && !speech.isSpeaking, "session activation failure discards prompt instead of interrupting another app")
session.failActivation = false
speech.speak("accepted after activation recovers")
let recovered = synth.submitted.last!
check(speech.isSpeaking, "failed activation leaves no stuck speech queue")
synth.emitFinish(recovered)
drain(0.5)
check(!speech.isSpeaking && !session.isActive, "recovered speech releases normally")

print("Production Speech adapter: \(checks) checks passed")
