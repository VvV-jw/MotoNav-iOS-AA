import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
let start = Date(timeIntervalSince1970: 1_700_000_000)
let first = MapReadinessState.Packet(type: 3, id: 10)
let replacement = MapReadinessState.Packet(type: 3, id: 11)
let gta = MapReadinessState.Packet(type: 1, id: 12)
func view(_ state: MapReadinessState, connected: Bool = true,
          coverage: MapReadinessSnapshot.Coverage = .unconfirmed,
          enabled: Bool = true, usesBasemap: Bool = true) -> MapReadinessSnapshot {
    state.snapshot(enabled: enabled, usesBasemap: usesBasemap, connected: connected, coverage: coverage)
}
var state = MapReadinessState()
check(view(state).phase == .idle && !view(state).hasPacket, "No map is not falsely reported as delivered")
check(view(state, enabled: false).phase == .disabled, "Disabled maps do not block readiness")
check(view(state, usesBasemap: false).phase == .notRequired, "Radar needs no basemap download")
check(!state.acknowledge(first, at: start), "An unsolicited ACK without a packet is ignored")
state.beginPreparation()
check(view(state).phase == .preparing, "Preparing is structured and independent of localized text")
state.accept(first)
check(!state.acknowledge(first, at: start), "A prepared packet cannot be ACKed before any send")
state.finishPreparation()
check(!state.beginSending(first, connected: false), "Absent connection cannot begin a transfer")
check(view(state, connected: false).phase == .waitingConnection, "An offline packet is ready only on the phone")
check(!state.acknowledge(first, at: start), "Late K while disconnected cannot restore map confirmation")
check(state.beginSending(first, connected: true), "A current packet may start sending on a live connection")
check(view(state).phase == .transferring, "Sending remains distinct from round-screen confirmation")
check(!state.acknowledge(replacement, at: start), "An ACK for another packet cannot confirm delivery")
check(state.acknowledge(first, at: start), "Only the exact sent identity is confirmed")
check(!state.acknowledge(first, at: start.addingTimeInterval(1)), "Duplicate K does not advance confirmed time")
check(view(state, coverage: .covered).phase == .confirmed, "Confirmation plus viewport coverage is ready")
check(view(state, coverage: .covered).confirmedAt == start, "Confirmation time belongs to the screen ACK")
state.cancelTransfer()
check(view(state, coverage: .covered).phase == .confirmed, "Ending navigation preserves an already confirmed retained map")
check(view(state, coverage: .unknown).title.contains("等待定位"), "An ACK without a position does not promise coverage")
check(view(state, coverage: .uncovered).phase == .stale, "Moving outside a confirmed block marks it stale")

// Regression: an older ACK must never mask the next block's preparation failure.
state.beginPreparation()
check(view(state, coverage: .covered).phase == .preparing, "Old confirmed map cannot hide in-progress replacement")
check(view(state, coverage: .covered).detail.contains("仍覆盖"), "Retained coverage is explained during preparation")
state.failPreparation("网络暂不可用", retryAt: start.addingTimeInterval(15))
check(view(state, coverage: .covered).phase == .retrying, "Old chunkAcked cannot mask replacement failure")
check(view(state, coverage: .covered).severity == .attention, "Replacement failure is visible even with usable old map")
check(view(state, coverage: .covered).retryAt == start.addingTimeInterval(15), "Retry deadline remains machine-readable")
check(view(state, coverage: .covered).detail.contains("网络暂不可用"), "Failure reason remains available without prefix parsing")
check(view(state, coverage: .uncovered).detail.contains("已不能覆盖"), "Lost coverage is explicit during a retry")
state.beginPreparation(); state.accept(replacement)
check(state.beginSending(replacement, connected: true), "Replacement send uses its own identity")
state.failPreparation("建筑准备失败", retryAt: start.addingTimeInterval(30))
check(state.acknowledge(replacement, at: start.addingTimeInterval(5)), "Base packet can finish during failed enrichment")
check(view(state, coverage: .covered).phase == .retrying, "A late base ACK cannot erase a building/fetch error")
state.finishPreparation()
check(view(state, coverage: .covered).phase == .confirmed, "Successful preparation clears its failure")

// Connection replacement and style changes invalidate old transfer identities.
state.disconnect()
check(view(state, connected: false).confirmedAt == nil, "Disconnect invalidates previous display confirmation")
check(!state.acknowledge(replacement, at: start), "An old-connection ACK is invalid")
state.accept(gta)
check(!state.beginSending(replacement, connected: true), "Late raster encoder cannot start after a GTA style change")
check(!state.acknowledge(replacement, at: start), "An old raster ACK cannot confirm a GTA map")
check(state.beginSending(gta, connected: true), "New style sends independently")
state.cancelTransfer()
check(!state.acknowledge(gta, at: start), "Cancellation invalidates pending confirmation")
state.waitForForeground()
check(view(state).phase == .waitingForeground, "Paused graphics capture has an explicit state")
state.cancelPreparation()
check(view(state).phase == .idle && view(state).hasPacket, "Cancelled navigation retains the packet without claiming an active transfer")
state.reset()
check(view(state).phase == .idle && !view(state).hasPacket, "Style reset cannot retain old readiness")

// Every normal lifecycle state yields meaningful, stable UI semantics for each coverage state.
for coverage in [MapReadinessSnapshot.Coverage.unknown, .unconfirmed, .covered, .uncovered] {
    var cycle = MapReadinessState()
    cycle.beginPreparation(); cycle.accept(first)
    _ = cycle.beginSending(first, connected: true)
    check(view(cycle, coverage: coverage).phase == .preparing, "Base transfer cannot obscure ongoing detail preparation")
    cycle.finishPreparation()
    check(view(cycle, coverage: coverage).phase == .transferring, "Completing preparation still needs a screen ACK")
    _ = cycle.acknowledge(first, at: start)
    check(!view(cycle, coverage: coverage).title.isEmpty && !view(cycle, coverage: coverage).detail.isEmpty, "All coverage cases have usable text")
    check(view(cycle, coverage: coverage, enabled: false).phase == .disabled, "Disabled takes precedence in every coverage case")
    check(view(cycle, coverage: coverage, usesBasemap: false).phase == .notRequired, "Radar takes precedence in every coverage case")
}

// Route readiness distinguishes baseline coverage from optional building enrichment.
check(!RouteMapPreparation.none.hasPlan && !RouteMapPreparation.none.isComplete, "No route is not marked as prepared")
let checking = RouteMapPreparation(phase: .checking, ready: 0, total: 10, detailedReady: 0, retryAt: nil, error: nil, detail: "校验缓存")
check(checking.hasPlan && checking.fraction == 0 && !checking.isComplete, "Cache validation exposes known work")
let baseReady = RouteMapPreparation(phase: .preparing, ready: 10, total: 10, detailedReady: 4, retryAt: nil, error: nil, detail: "补齐建筑")
check(baseReady.isComplete && !baseReady.isDetailedComplete, "All usable bases permit departure while buildings finish")
check(baseReady.fraction == 1, "Preparation fraction reflects usable basemaps")
let retry = RouteMapPreparation(phase: .retrying, ready: 4, total: 10, detailedReady: 2,
    retryAt: start.addingTimeInterval(15), error: "存储不足", detail: "保留已保存地图")
check(retry.hasPlan && !retry.isComplete && retry.fraction == 0.4, "Partial route data remains available through retry")
check(retry.retryAt != nil && retry.error == "存储不足", "Retry deadline and error do not require parsing display strings")
let complete = RouteMapPreparation(phase: .complete, ready: 10, total: 10, detailedReady: 10, retryAt: nil, error: nil, detail: "全部完成")
check(complete.isComplete && complete.isDetailedComplete && complete.phase == .complete, "Full route readiness is explicit")
let invalid = RouteMapPreparation(phase: .failed, ready: 0, total: 0, detailedReady: 0, retryAt: nil, error: "无效路线", detail: "重新选择路线")
check(invalid.hasPlan && !invalid.isComplete && invalid.fraction == 0, "Invalid plans cannot show a misleading 100 percent")
print("Map readiness lifecycle: \(checks) checks passed")
