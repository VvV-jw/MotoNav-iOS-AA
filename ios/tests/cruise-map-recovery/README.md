# Cruise Map Recovery

Run on macOS with `bash ios/tests/cruise-map-recovery/run.sh`.
The main regression runner also includes this suite.

This runs the production `MapFeeder`, coverage calculations, packet codecs, disk
cache and BLE fragment queue. iOS services, provider calls and unrelated route
prefetch/storage services are replaced at their boundaries. An injected clock
advances retry deadlines without sleeping, and the main run loop delivers real
worker callbacks.

The replay covers:

- A missing map acknowledgement while the car leaves the old coverage.
- Late acknowledgements and ATT failures after a replacement map is queued.
- Manual refresh preserving queued navigation-route fragments.
- Finished cruise packets persisted at their selected cache nodes.
- Reconstructing the cache and controller reuses saved packets without a provider.
- Heartbeat fetch retries without a new GPS fix, with a fresh retained pose.
- Refusing new downloads when the retained pose is older than 15 seconds.
- Cancelled provider work finishing after the car has moved.
- Retained-packet acknowledgement retries while map preparation is memory-paused.
- Fixed 180/200 km/h poses avoiding repeated same-center preparation or delivery.
- Rich POI caches preserved while sending AA13-compatible legacy wire packets.

It does not simulate radio reception, actual road coverage or an iOS background
execution budget. Device ride verification is still necessary.
