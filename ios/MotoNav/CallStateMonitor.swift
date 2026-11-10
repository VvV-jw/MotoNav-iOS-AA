import Foundation
import Combine
import CallKit
import UIKit

/// Observes system-visible phone/CallKit calls without reading phone numbers,
/// recording audio, or claiming to identify the app that owns a call.
final class CallStateMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = CallStateMonitor()
    @Published private(set) var state: CallState = .inactive
    var onStateChanged: ((CallState) -> Void)?

    private var observer = CXCallObserver()
    private var running = false
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []

    private override init() { super.init() }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard !running else { refresh(force: true); return }
        running = true
        observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh(force: true)
            })
        }
        // Common mode also runs while the user scrolls. The display sync layer
        // still limits unchanged status heartbeats to one every ten seconds.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh(force: true) }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh(force: true)
    }

    /// Re-read the live observer before a BLE reconnect/heartbeat republishes
    /// state, so a queued foreground snapshot cannot resurrect an ended call.
    func refresh(force: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(force: force) }
            return
        }
        let current = running ? observer.calls.map(Self.snapshot) : []
        publish(CallStateReducer.state(for: current), force: force)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop() }
            return
        }
        running = false
        observer.setDelegate(nil, queue: nil)
        timer?.invalidate()
        timer = nil
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        publish(.inactive, force: true)
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard running, callObserver === observer else { return }
        let current = CallStateReducer.applying(Self.snapshot(call), to: callObserver.calls.map(Self.snapshot))
        publish(CallStateReducer.state(for: current))
    }

    private static func snapshot(_ call: CXCall) -> CallStateReducer.Call {
        CallStateReducer.Call(id: call.uuid, isOutgoing: call.isOutgoing,
                              hasConnected: call.hasConnected, hasEnded: call.hasEnded,
                              isOnHold: call.isOnHold)
    }

    private func publish(_ value: CallState, force: Bool = false) {
        let changed = state != value
        if changed { state = value }
        if changed || force { onStateChanged?(value) }
    }

    deinit {
        observer.setDelegate(nil, queue: nil)
        timer?.invalidate()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }
}
