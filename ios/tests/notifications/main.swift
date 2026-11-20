import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

var state = NotificationLinkState()
check(!state.supported && !state.ready, "No inherited subscription before discovery")
check(state.status(connected: false) == "连接圆屏后查看通知状态", "Offline status takes precedence")
check(state.status(connected: true) == "正在确认圆屏通知支持", "Unknown capability is not denial")
check(state.receive("CAP,ANCS,1"), "Recognize the accessory capability")
check(state.supported && !state.ready, "Capability does not establish subscription")
check(state.status(connected: true) == "等待 iPhone 通知连接", "Waiting does not claim permission denial")
check(state.receive("ANC,1") && state.ready, "A real subscription reply marks ready")
check(state.status(connected: true) == "iPhone 通知已连接", "Ready status follows the accessory reply")
check(state.status(connected: false) == "连接圆屏后查看通知状态", "Disconnect cannot display an old ready status")
let readyState = state
for packet in ["ANC,2", "ANC,-1", "ANC,true", "ANC,1,extra", "CAP,ANCS,2",
               "CAP,ANCS,0", "ANC,01", " ANC,1", "ANC,1\n", "HID,1,1", ""] {
    check(!state.receive(packet) && state == readyState, "Unknown replies cannot change state")
}
check(state.receive("CAP,ANCS,1") && state.ready, "Capability retries preserve an established subscription")
check(state.receive("ANC,0") && state.supported && !state.ready, "Subscription loss clears ready")
state.reset()
check(!state.supported && !state.ready, "Reconnect clears both capability and subscription")
check(state.receive("ANC,1") && state.supported && state.ready, "Status recovers even if capability packet was lost")
state.reset()
check(state.receive("ANC,0") && state.supported && !state.ready, "Waiting reply also proves protocol support")
print("Notification link: \(checks) checks passed")
