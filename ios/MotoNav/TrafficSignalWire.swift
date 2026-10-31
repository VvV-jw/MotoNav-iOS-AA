import Foundation

/// Monotonic, transient traffic-signal payloads shared with the firmware.
///
/// Android writes the remaining time and lease in milliseconds immediately
/// before the BLE write. Keeping that rule here prevents queue latency from
/// extending a stale countdown on the display.
protocol TrafficSignalWrite {
    func expired(nowMs: Int64) -> Bool
    func encode(nowMs: Int64) -> String?
}

struct TrafficSignalPacket: TrafficSignalWrite, Equatable {
    let status: Int
    let dir: Int
    let wait: Int
    let show: Int
    let remainingMs: Int64
    let atMs: Int64
    let expiresAtMs: Int64

    init?(status: Int, dir: Int, wait: Int, show: Int,
          remainingMs: Int64, atMs: Int64, expiresAtMs: Int64) {
        guard (-1...255).contains(status),
              [0, 1, 2, 4].contains(dir),
              (0...999).contains(wait),
              (0...255).contains(show),
              (0...999_000).contains(remainingMs),
              atMs >= 0,
              expiresAtMs > atMs,
              expiresAtMs - atMs <= 3_000 else { return nil }
        self.status = status
        self.dir = dir
        self.wait = wait
        self.show = show
        self.remainingMs = remainingMs
        self.atMs = atMs
        self.expiresAtMs = expiresAtMs
    }

    func expired(nowMs: Int64) -> Bool {
        nowMs < atMs || nowMs >= expiresAtMs || nowMs - atMs >= 400
    }

    func remaining(nowMs: Int64) -> Int64 {
        max(0, remainingMs - max(0, nowMs - atMs))
    }

    func seconds(nowMs: Int64) -> Int {
        Int((remaining(nowMs: nowMs) + 999) / 1_000)
    }

    func encode(nowMs: Int64) -> String? {
        guard !expired(nowMs: nowMs) else { return nil }
        return "#TL,1,\(status),\(remaining(nowMs: nowMs)),\(dir),\(wait),\(show),\(expiresAtMs - nowMs)"
    }
}

/// One atomic junction snapshot. A mixed-time batch is rejected so the display
/// never combines a fresh direction with a stale countdown.
struct TrafficSignalBatchPacket: TrafficSignalWrite, Equatable {
    let lights: [TrafficSignalPacket]
    let atMs: Int64

    init?(lights: [TrafficSignalPacket], atMs: Int64) {
        guard (1...4).contains(lights.count), atMs >= 0 else { return nil }
        var directions = Set<Int>()
        for light in lights {
            guard light.atMs == atMs, directions.insert(light.dir).inserted else { return nil }
        }
        self.lights = lights
        self.atMs = atMs
    }

    func expired(nowMs: Int64) -> Bool {
        nowMs < atMs || nowMs - atMs >= 400 || lights.contains { $0.expired(nowMs: nowMs) }
    }

    func encode(nowMs: Int64) -> String? {
        guard !expired(nowMs: nowMs) else { return nil }
        var fields = ["#TLS", "1", String(lights.count)]
        for light in lights {
            fields.append(contentsOf: [
                String(light.dir),
                String(light.status),
                String(light.remaining(nowMs: nowMs)),
                String(light.wait),
                String(light.show),
                String(light.expiresAtMs - nowMs)
            ])
        }
        return fields.joined(separator: ",")
    }
}
