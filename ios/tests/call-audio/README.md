# Call State and Navigation Audio

Run with `bash ios/tests/call-audio/run.sh` on the macOS Swift runner.

The first executable compiles the production `CallState.swift` and
`SpeechVolumePolicy.swift` reducers. It checks multiple-call precedence, ended
calls, stale foreground delegate events, persisted navigation gain, call
suppression, discarded queued prompts, late completion tokens, capability
negotiation, disconnects, reconnects and ten second display heartbeats.

The second executable compiles the actual production `Speech.swift` against a
test-only AVFoundation module. It records utterance submission and audio session
activation, injects late finish/cancellation callbacks, and runs the real delayed
release closure on the main run loop. It verifies gain, zero-gain silence, call
suppression, stale callback isolation, and failed session activation. The iPhone
application continues to compile and link the real Apple framework.

The application adapter uses `CXCallObserver.calls` and its delegate on the main
queue, rechecks on foreground entry and every five seconds while executing, and
publishes an explicit inactive state when stopped. BLE reconnects must call
`refresh(force: true)` before resending the status. A suspended or terminated app
cannot guarantee background delivery; the screen must expire a lost status
heartbeat rather than retain an old call icon.

Only system-visible calls are known. No microphone permission, audio
interruption heuristic, caller number, VoIP background mode, or source-app
identification is used. A WeChat call that is not reported to system CallKit
cannot be detected by this API.

`Speech.shared.updateCallState` must receive each call state before navigation
speech is allowed. Ringing, dialing, active and held states stop current
navigation speech and discard its queue. Only new instructions may speak after
the call ends. `nav_voice_volume` controls this app's utterance gain, from zero to
one; it cannot raise system volume or adjust another app's music/call mix.

Primary Apple references checked November 10, 2026:

- https://developer.apple.com/documentation/callkit/cxcallobserver
- https://developer.apple.com/documentation/callkit/cxcall
- https://developer.apple.com/documentation/avfaudio/avspeechutterance/volume
- https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume

These tests do not establish real-device WeChat visibility, system background
delivery, or headset call/media volume behavior.
