import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    checks += 1
}

var device = RoundDeviceState()
check(device.name == "我的圆屏" && device.batteryPercent == nil, "Unknown device has no fabricated identity or power")
device.identify(" MotoNav-4679 ")
check(device.name == "MotoNav-4679", "Display the peripheral's actual name")
device.identify(nil)
device.identify("")
device.identify("invalid\nname")
check(device.name == "MotoNav-4679", "An absent or malformed callback must not erase a known name")
device.transition(to: .searching)
check(device.connection.busy, "Searching offers a real stop action")
check(device.receivePower("V,83,0,0,4030") && device.batteryPercent == nil, "A delayed old power packet is ignored before readiness")
device.transition(to: .ready)
check(device.receivePower("V,83,0,0,4030"), "Parse the existing accessory V packet")
check(device.batteryPercent == 83 && device.batteryText == "83%" && !device.charging, "Use accessory percentage")
check(device.receivePower("V,24,1,1,3700") && device.charging && device.usbConnected, "Keep charging and USB state")
let valid = device
for packet in ["V,101,0,0,4000", "V,-2,0,0,4000", "V,72,2,0,4000", "V,72,0,1,-1",
               "V,72,0,1,7000", "V,72,0,1", "V,72,0,1,4000,extra", "V,,0,0,4000", "ANC,1"] {
    check(!device.receivePower(packet) && device == valid, "Reject invalid power without corrupting the last sample: \(packet)")
}
check(device.receivePower("V,-1,0,1,0") && device.batteryText == "USB 供电", "USB-only hardware has no invented percentage")
device.transition(to: .retrying)
check(device.batteryPercent == nil && !device.usbConnected && device.batteryText == "—", "A disconnect clears stale battery and charging")
device.transition(to: .idle)
check(!device.connection.busy && device.connection.title == "未连接", "Stop search returns to a truthful idle state")
device.transition(to: .ready)
check(device.batteryPercent == nil, "Reconnect waits for new accessory telemetry")
check(device.receivePower("V,0,0,0,0") && device.batteryText == "0%", "Zero is a valid known battery percentage")
check(device.receivePower("V,100,0,1,4200") && device.batteryText == "100%", "Full battery remains bounded")

check(MapStylePolicy.isValid(12) && MapStylePolicy.usesVector(12), "Floating navigation uses the real vector pipeline")
check(MapStylePolicy.half(12) == 2400 && !MapStylePolicy.usesAmapCapture(12), "Keep the vector extent and background recovery path")
check(MapStylePolicy.cacheKey(theme: 12, buildings: true) != MapStylePolicy.cacheKey(theme: 2, buildings: true),
      "New appearance has its own content identity")
check(MapStylePolicy.isValid(13) && MapStylePolicy.usesVector(13), "Coast navigation uses the real vector pipeline")
check(MapStylePolicy.half(13) == 2400 && !MapStylePolicy.usesAmapCapture(13), "Coast retains vector extent and offline/background recovery")
check(MapStylePolicy.cacheKey(theme: 13, buildings: false) == "ofm-coast-areas-v1",
      "Coast areas have their own content identity")
for previous in 0...12 {
    check(MapStylePolicy.cacheKey(theme: 13, buildings: false) != MapStylePolicy.cacheKey(theme: previous, buildings: false),
          "Coast cannot reuse a packet from another map style")
}
check(MapStylePolicy.usesNativeRoadText(12) && MapStylePolicy.usesNativeRoadText(13),
      "Floating and coast instructions use the same stable native text cell")
check(!MapStylePolicy.usesNativeRoadText(2) && !MapStylePolicy.usesBuildings(13, enabled: true),
      "Existing GTA text and raster-only building preference stay unchanged")
print("Device state, floating and coast navigation: \(checks) checks passed")
