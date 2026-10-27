import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
let began = Date(timeIntervalSince1970: 10_000)
let deadline = began.addingTimeInterval(20)
var notice = IndependentRecalculationNotice()
check(notice.snapshot(at: began) == nil, "ordinary navigation has no extra notice")
notice.resetSession()
let first = notice.beganAttempt()
check(notice.snapshot(at: began) == nil, "first attempt uses the existing recalculation status")
check(notice.failed("网络不可用", ticket: first, retryNotBefore: deadline), "accept current failure")
check(notice.snapshot(at: began.addingTimeInterval(5))?.remainingSeconds == 15,
      "deadline uses the existing request start, not failure completion time")
check(notice.snapshot(at: began.addingTimeInterval(5))?.phase == .failed, "failure is independent state")
check(notice.snapshot(at: began)?.reason == "网络不可用", "preserve useful failure cause")
check(notice.snapshot(at: began)?.title.contains("保留原路线") == true, "old route remains explicit")
check(notice.snapshot(at: began.addingTimeInterval(19.2))?.remainingSeconds == 1, "round up last partial second")
check(notice.snapshot(at: deadline)?.remainingSeconds == 0, "cooldown endpoint is zero")
check(notice.snapshot(at: deadline.addingTimeInterval(1))?.retryHint.contains("有效定位") == true,
      "zero countdown never promises a timer-driven request")

// Repeated valid-but-off-route fixes, GPS warning updates and view refreshes
// do not mutate this policy. Failure remains readable throughout the cooldown.
for tick in 0..<600 {
    let snapshot = notice.snapshot(at: began.addingTimeInterval(Double(tick)/10))
    check(snapshot?.reason == "网络不可用", "ordinary fixes and GPS status cannot erase failure")
    check(snapshot?.remainingSeconds == max(0, Int(ceil(20-Double(tick)/10))), "countdown follows one deadline")
}
let retry = notice.beganAttempt()
check(notice.snapshot(at: deadline)?.phase == .retrying, "retry updates its own presentation")
check(notice.snapshot(at: deadline)?.detail.contains("网络不可用") == true, "retain prior cause while retrying")
check(!notice.failed("旧请求晚到", ticket: first, retryNotBefore: deadline), "old attempt cannot replace newer retry")
check(!notice.succeeded(ticket: first), "old success cannot clear current retry")
check(notice.snapshot(at: deadline)?.reason == "网络不可用", "rejecting old callbacks preserves state")
check(notice.succeeded(ticket: retry), "current retry succeeds")
check(notice.snapshot(at: deadline) == nil, "success clears failure")
check(!notice.failed("成功后的重复失败", ticket: retry, retryNotBefore: deadline), "duplicate callbacks do not resurrect failure")

let returnedAttempt = notice.beganAttempt()
check(notice.failed("请求超时", ticket: returnedAttempt, retryNotBefore: deadline), "new failure can be shown")
notice.returnedToEffectiveRoute()
check(notice.snapshot(at: deadline) == nil, "fresh tracker-confirmed return clears failure")
let inFlightReturn = notice.beganAttempt()
notice.returnedToEffectiveRoute()
check(!notice.failed("回到原路线后的晚失败", ticket: inFlightReturn, retryNotBefore: deadline),
      "an in-flight failure cannot resurrect a notice after returning to the effective route")
check(notice.snapshot(at: deadline) == nil, "returned route remains clean")

let stoppedAttempt = notice.beganAttempt()
notice.resetSession()
check(!notice.failed("终止后晚失败", ticket: stoppedAttempt, retryNotBefore: deadline), "stop invalidates presentation ticket")
check(!notice.succeeded(ticket: stoppedAttempt), "stop invalidates late success")
let nextSession = notice.beganAttempt()
check(notice.failed("当前自行车会话失败", ticket: nextSession, retryNotBefore: deadline), "new session accepts its own result")
check(!notice.failed("旧摩托车会话失败", ticket: stoppedAttempt, retryNotBefore: deadline), "mode/session replacement rejects old callback")
check(notice.snapshot(at: began)?.reason == "当前自行车会话失败", "old session cannot overwrite new cause")
notice.resetSession()
check(notice.snapshot(at: began) == nil, "accepted replacement clears previous notice")

let long = notice.beganAttempt()
check(notice.failed(String(repeating:"错",count:1000),ticket:long,retryNotBefore:deadline), "long message accepted safely")
check(notice.snapshot(at: began)?.reason.count == 400, "display state has bounded reason length")
let blank = notice.beganAttempt()
check(notice.failed(" \n\t ",ticket:blank,retryNotBefore:deadline), "empty provider explanation accepted")
check(notice.snapshot(at: began)?.reason == "路线服务未返回可用结果", "empty reason has useful fallback")
let whitespace = notice.beganAttempt()
check(notice.failed("请求\n失败\t请重试",ticket:whitespace,retryNotBefore:deadline), "multiline reason accepted")
check(notice.snapshot(at: began)?.reason == "请求 失败 请重试", "collapse provider whitespace")
check(notice.snapshot(at: began.addingTimeInterval(-1))?.remainingSeconds == 21,
      "clock rollback mirrors existing wall-clock limiter without inventing a different deadline")
check(notice.snapshot(at: began.addingTimeInterval(-200_000))?.remainingSeconds == nil,
      "abnormal clock intervals remain bounded without integer overflow")
let nonfinite = notice.beganAttempt()
check(notice.failed("等待时钟",ticket:nonfinite,retryNotBefore:Date(timeIntervalSince1970: .nan)), "invalid clock never crashes notice")
check(notice.snapshot(at: began)?.remainingSeconds == nil, "nonfinite interval gives neutral wait explanation")
check(notice.snapshot(at: began)?.retryHint.contains("检查") == true, "unknown deadline does not claim immediate retry")
print("PASS independent recalculation notice: \(checks) checks; failure/fixes/cooldown/retry/success/return/stop/stale callbacks")
