# MotoLink web 0.3 independent review

Reviewed `dist/app.js`, `ble.js`, `diagnostic.js`, `storage.js`, `rides.js`, `protocol.js`, and `index.html` in the in-progress checkout. Read-only review: no Site source or lifecycle changes by reviewer. Findings communicated to the owner before final testing.

## Corrections needed before delivery

1. **Old GATT write can close a replacement connection.** `BikeConnection.query` closes `this.context` unconditionally when its awaited write fails. A cancelled old session may still have a pending write; after the user establishes a new session, rejection/timeout of that write closes the new session. Reproduced against the actual module with a deferred old write, manual close, replacement context, then old-write rejection: `{newSessionSurvived:false,newSessionClosed:true}`. Only close if `this.current(c)`. Test the stale-write rejection/timeout case with a surviving replacement context.

2. **Malformed stream packet suppresses fallback.** The app increments `frames[74]` for every 0x4A prefix before validation. The diagnostic uses this count to decide whether the main path succeeded, and the final UI uses it to claim stream reception. Keep all raw counts, but use a separate valid/known-layout 0x4A counter for the fallback and success indication. A malformed 4A must remain in the raw export and must not disable the backup attempt.

3. **Latest fallback ride is overwritten by stale IndexedDB copy.** A failed IndexedDB write falls back to localStorage, but `Journal.rides()` merges local entries first and database entries second. When the database still has an older version of the same ride, Map overwrite restores that older version on reload. Record a modification timestamp and pick the most recent copy; do not silently prefer database storage over data freshness.

4. **Double stop action races global active ride.** `stopRide()` awaits persistence while the stop button remains enabled. A second invocation can pass the `ride` guard; the first invocation later sets `ride = null`, and the second continuation dereferences `ride.id`. Capture the finished ride, immediately lock the stop action, detach GPS, and update active state consistently before awaiting persistence.

## Smaller lifecycle and decoding observations

- Initial `toggleMonitor()` may continue sending its next request after the user has pressed its stop button, because the flag is not checked after its awaits. Add an operation token or check that the same monitoring operation remains active between requests.
- Stream decoding currently accepts a block byte 5 equal to 0x05 and any byte 6 other than 0xFF. This needs checking against the protocol audit: an unknown subtype should remain raw, not inherit unrelated offsets.
- Do not simply treat throttle byte 0xFF as missing: upstream mode 1 scales the full byte to 100%, so there is ambiguity without field evidence. Experimental labeling and model validation remain necessary.
- Ride telemetry rows combine samples from different measurement times into one row timestamp. Exporting each sample's original time/source alongside its value would make later analysis less ambiguous; the raw event journal currently preserves the evidence.
- Some archive-import sessions may reuse numeric session IDs across browser launches. A connection boundary should reset imported capability state even when its numeric session ID happens to match the earlier launch.

## Positive checks

- Reads and writes are serialized through one pending request, with explicit ACK-only outcomes; response waiting exists before the GATT write so early replies can be collected.
- Subscription setup must finish on all three channels before readiness.
- Notifications retain full bytes and characteristic UUIDs; display log truncation is separated from IndexedDB storage. Memory fallback reports event loss rather than silently claiming complete capture.
- Current measurements require same-session capability state, are cleared on disconnect, and have visible freshness limits.
- GPS speed/distance are explicitly separate from motorcycle wheel speed. Poor/future/old GPS points are rejected, long gaps split route segments, and GPX preserves those breaks.
- Web foreground limitations are clearly disclosed. The interface does not claim native background reconnection already works.

This review does not certify physical behavior of EX500G streaming commands, compilation of the native iOS project, or a successful real motorcycle run. Those are separate evidence requirements.

## Resolution before release

The owner fixed all four delivery blockers and monitoring cancellation before publication.
Transport regression tests confirm late old-write failure leaves replacement connection alive.
Only structurally valid4A packets suppress fallback; unknown schemas stay in the raw journal.
Ride persistence merges by updatedAt; stopRide detaches and locks active state before awaiting.
GPS distance now uses a separate accumulated-distance anchor.
Each trip telemetry row now retains original per-field timestamps and frame source.
Imported connection boundaries clear capability state.
30web tests passed after these changes, including the actual UI entrypoint with a mocked BLE transport.
Experimental4A block identification remains a declared field-validation limitation, not a fixedhardwarefact.
