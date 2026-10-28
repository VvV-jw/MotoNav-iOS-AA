import Foundation
var checks = 0
func check(_ truth: Bool, _ reason: String) { precondition(truth, reason); checks += 1 }
func packet(_ field: UInt8, _ revision: UInt16, _ data: Data, part: UInt8 = 0, count: UInt8 = 1, gen: UInt32 = 1, partial: Bool = false) -> Data {
    Data([0xa6] + (0..<4).map { UInt8(truncatingIfNeeded: gen >> ($0 * 8)) } + [UInt8(truncatingIfNeeded: revision), UInt8(revision >> 8), field, part, count, partial ? 1 : 0]) + data
}
func text(_ f: UInt8, _ r: UInt16, _ s: String, gen: UInt32 = 1) -> Data { packet(f, r, Data(s.utf8), gen: gen) }
var model = AMSMetadata()
check(model.receive(text(6, 1, "READY")), "service ready")
let song = Data("夜曲，Live 🎵".utf8), first = song.prefix(2), last = song.dropFirst(2)
check(!model.receive(packet(0, 1, Data(last), part: 1, count: 2)), "wait for earlier UTF8 bytes")
check(model.title.isEmpty, "no partial decode")
check(model.receive(packet(0, 1, Data(first), count: 2)), "assemble out of order")
check(model.title == "夜曲，Live 🎵", "Chinese comma and emoji round trip")
check(!model.receive(text(0, 1, "duplicate")), "reject duplicate completed revision")
check(model.receive(text(0, 3, "新歌")), "new track")
check(!model.receive(text(0, 2, "旧歌")), "reject stale track")
check(model.receive(text(1, 2, "歌手")), "artist")
check(model.receive(text(2, 2, "专辑")), "album")
check(model.receive(text(5, 2, "网易云音乐")), "player")
check(model.summary.contains("网易云音乐"), "source shown")
check(model.receive(text(4, 1, "1,1.0,16.500")) && model.playing == true, "playing")
check(model.receive(text(4, 2, "0,0.0,17")) && model.playing == false, "paused")
check(model.receive(text(4, 3, "bad")) && model.playing == nil, "bad state unknown")
check(model.receive(packet(0, 4, Data("截断".utf8), partial: true)), "truncated flag")
check(model.summary.contains("截断…"), "truncation visible")
check(model.receive(text(0, 5, "完整歌名")) && !model.values[0].partial, "full read supersedes partial")
check(!model.receive(packet(0, 6, Data([0xff]))), "invalid UTF8 ignored")
check(!model.receive(packet(0, 7, Data(repeating: 65, count: 513))), "bound memory")
check(!model.receive(packet(8, 1, Data())), "bad field")
check(!model.receive(packet(0, 8, Data(), count: 0)), "bad part count")
check(model.receive(text(6, 1, "SEARCHING", gen: 2)), "new service generation")
check(model.title.isEmpty && !model.ready, "clear stale track and state")
check(!model.receive(text(0, 100, "上个连接", gen: 1)), "reject old connection callback")
check(model.receive(text(0, 65535, "wrap start", gen: 2)), "first revision any")
check(model.receive(text(0, 1, "wrap end", gen: 2)), "revision wrap")
model.reset()
check(model.generation == nil && model.title.isEmpty, "disconnect reset")
check(model.receive(text(6, 1, "READY", gen: 1)), "reboot generation accepted after disconnect")
check(!model.receive(packet(0, 1, Data([65]), count: 2)), "pending part")
check(!model.receive(packet(0, 2, Data([66]), count: 2)), "new revision retires pending")
check(!model.receive(packet(0, 1, Data([67]), part: 1, count: 2)), "old fragment ignored")
check(model.receive(packet(0, 2, Data([68]), part: 1, count: 2)) && model.title == "BD", "latest fragments complete")

// Reproduce an ESP reboot while iPhone music is already playing. CAP,HID and
// the first mode ACK can be lost; recovery must not depend on toggling the UI.
var connection = MediaConnectionSync()
check(connection.modeCommand(now: 0, ready: false) == nil, "no media writes while disconnected")
check(connection.modeCommand(now: 0, ready: true) == "#HM,1", "restore chosen mode without an unsolicited capability")
check(connection.modeCommand(now: 1.99, ready: true) == nil, "no retry storm")
check(connection.modeCommand(now: 2, ready: true) == "#HM,1", "recover lost first mode command or reply")
check(connection.modeCommand(now: 5.99, ready: true) == nil, "exponential mode backoff")
check(connection.modeCommand(now: 6, ready: true) == "#HM,1", "second mode retry")
connection.acknowledge(true)
check(connection.modeCommand(now: 100, ready: true) == nil, "matching mode ACK ends retries")
check(connection.snapshotCommand(now: 100, ready: true, metadataReady: false) == "#AMS?", "query fresh metadata after mode confirmed")
check(connection.snapshotCommand(now: 101, ready: true, metadataReady: false) == nil, "snapshot query throttled")
check(connection.snapshotCommand(now: 102, ready: true, metadataReady: false) == "#AMS?", "recover lost initial metadata fields")
check(connection.snapshotCommand(now: 106, ready: true, metadataReady: true) == nil, "complete initial snapshot stops queries")
check(connection.snapshotCommand(now: 107, ready: true, metadataReady: false) == "#AMS?", "new AMS generation can recover again")
connection.reset()
check(connection.modeCommand(now: 108, ready: true) == "#HM,1", "screen reboot clears old mode ACK")
check(connection.snapshotCommand(now: 108, ready: true, metadataReady: false) == nil, "wait for current link ACK before snapshot")
connection.acknowledge(true)
connection.configure(false)
check(connection.modeCommand(now: 109, ready: true) == "#HM,0", "App mode takes effect immediately")
connection.acknowledge(true)
check(!connection.desired, "stale HID ON reply does not change user preference")
check(connection.modeCommand(now: 111, ready: true) == "#HM,0", "repair stale ON reply with selected OFF")
check(connection.snapshotCommand(now: 111, ready: true, metadataReady: false) == nil, "App mode never restarts AMS")
connection.acknowledge(false)
check(connection.modeCommand(now: 200, ready: true) == nil, "OFF ACK stops retry")
connection.reset()
check(connection.modeCommand(now: .nan, ready: true) == nil, "reject invalid retry clock")
check(connection.modeCommand(now: .infinity, ready: true) == nil, "reject infinite retry clock")
check(connection.modeCommand(now: 201, ready: true) == "#HM,0", "reconnect preserves latest OFF setting")

var initial = AMSMetadata()
check(initial.receive(text(6, 1, "READY")) && !initial.snapshotReady, "READY alone is not a complete metadata snapshot")
for field in UInt8(0)..<UInt8(6) { check(initial.receive(text(field, 1, field == 0 ? "正在播放" : "")), "initial field including empty metadata accepted") }
check(initial.snapshotReady, "all seven complete fields end snapshot retry")
check(initial.receive(text(6, 2, "SEARCHING")) && !initial.snapshotReady, "service reset invalidates snapshot readiness")

// If an older screen never replies, at most one tiny mode command per 30s is
// emitted after backoff. No navigation cancellation, playback or mode toggles.
var missing = MediaConnectionSync(), sentTimes: [Int] = []
for second in 0..<3600 {
    if let command = missing.modeCommand(now: Double(second), ready: true) {
        check(command == "#HM,1", "recovery only repeats the desired mode")
        sentTimes.append(second)
    }
}
check(Array(sentTimes.prefix(6)) == [0, 2, 6, 14, 30, 60], "mode retry schedule bounded")
check(zip(sentTimes.dropFirst(5), sentTimes.dropFirst(6)).allSatisfy { pair in pair.1 - pair.0 >= 30 }, "steady retry interval remains at least 30s")
print("AMS metadata: \(checks) checks passed")
