# Preparation recovery and combined-event stress

`run.sh` compiles the production scheduling policy, provider gate, recovery store,
route worker, real map packet validation and disk cache. Only the provider and
platform boundary is replaced by the existing offline-preparation SDK stubs.

The shared `fixtures/preparation-stress-v1.json` is also replayed by Android.
It has 1,801 events over **9,000 seconds of accelerated scheduler time** with
network backoff, 429/503 cooldown, optional Wi-Fi/charging changes, cancellation,
replanning, restart, cache expiry, foreground cache fills and cleanup. This part
advances an injected clock. The test harness models external events around the
actual production policies; it does not run navigation, GPS, BLE or SDKs for
2.5 hours.

Independent real-thread/disk checks cover:

- 5,000 updates through the production coalesced checkpoint writer, latest-state
  read after a new store instance, unchanged forced-refresh cutoff and old-owner
  rejection. Pending snapshot and successful disk-write counters come from the
  production store. On iOS, the pending count excludes the single running write.
- Cancel and replacement after a real temporary file was prepared but before
  publication, plus corrupt and oversized checkpoint reads.
- Cold durable provider cooldown, a one-hour clock rollback, repeated restart
  at the same clock and eventual cooldown expiry without a provider call storm.
- Eight real worker cycles with a blocked provider, memory pause/repeated resume,
  owner closure, replacement policy wait, foreground cache fill and cleanup.
  The provider concurrency counter is measured per owner; cache protection and
  directory-scan counters come from the actual production cache.

The JSON report is `preparation-stress-ios.json` under `MOTONAV_TEST_OUTPUT`.
`tools/tests/Test-Mobile-Preparation-Stress-Parity.py` compares all scheduler
states and deterministic cooldown results with Android, and checks each host's
observed worker and persistence bounds. It does not compare host timings or
nondeterministic write-coalescing counts, measure heap usage, or claim display
FPS or physical-device stability.
