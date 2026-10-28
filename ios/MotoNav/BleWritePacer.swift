import Foundation

/// CoreBluetooth backpressure protects the host stack, not the display's 47-packet RX ring.
/// Share one burst budget across all pump calls, including ready callbacks and navigation updates.
struct BleWritePacer {
    static let burst = 6
    static let interval: TimeInterval = 0.02
    private var window: TimeInterval?
    private var used = 0
    private var receiverFrameMS = 0.0
    private var effectiveInterval: TimeInterval { max(Self.interval, receiverFrameMS / 4000) }
    /// The firmware drains at most 30 RX messages between full frames. Leave
    /// headroom for navigation and callbacks while large maps are being sent.
    mutating func observeReceiver(drawMS: Double, flushMS: Double) {
        guard drawMS.isFinite, flushMS.isFinite, drawMS >= 0, flushMS >= 0,
              drawMS <= 3000, flushMS <= 3000 else { return }
        let observed = max(drawMS, flushMS)
        receiverFrameMS = max(observed, receiverFrameMS * 0.8)
    }
    mutating func take(now: TimeInterval) -> Bool {
        if window == nil || now - window! >= effectiveInterval { window = now; used = 0 }
        guard used < Self.burst else { return false }
        used += 1
        return true
    }
    func delay(now: TimeInterval) -> TimeInterval {
        max(0.001, effectiveInterval - (now - (window ?? now)))
    }
    mutating func reset() { window = nil; used = 0; receiverFrameMS = 0 }
}
