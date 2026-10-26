import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func state(_ permission: LocationReadiness.Permission = .allowed, _ age: Double? = 2,
           _ accuracy: Double? = 10, valid: Bool = true, precise: Bool = true) -> LocationReadiness.Result {
    LocationReadiness.evaluate(permission: permission, fixAge: age, accuracy: accuracy,
        validCoordinate: valid, fullAccuracy: precise)
}
check(state().usable, "fresh precise fix should be ready")
for permission in [LocationReadiness.Permission.unknown, .denied, .restricted] {
    check(!state(permission).usable, "old coordinates cannot bypass revoked authorization")
}
check(!state(.allowed, nil, nil).usable, "no fix")
for age in [Double.nan, Double.infinity, -6, 20.001, 3600] {
    check(!state(.allowed, age).usable, "stale or invalid fix must not say ready")
}
for accuracy in [Double.nan, Double.infinity, -1, 100.001, 1e300] {
    check(!state(.allowed, 1, accuracy).usable, "invalid or imprecise fix")
}
check(state(.allowed, 20, 100).usable, "boundary fix remains usable")
check(!state(valid: false).usable, "invalid coordinate")
check(!state(precise: false).usable, "reduced accuracy must be visible")
check(state(.allowed, -5).usable, "small clock skew tolerated")
check(state(.allowed, 1, 0).usable, "zero accuracy does not mean no fix")
print("Location readiness: \(checks) checks passed")
