# Nuvex Phase 1 — Performance Fixes

## Changed files
- `lib/features/home/services/thumbnail_batch_manager.dart`
- `lib/features/home/photos_screen.dart`

## Changes made
1. Removed synchronous filesystem checks from the thumbnail cache resolution path. Cache existence/size checks and HQ thumbnail validation now use asynchronous file APIs.
2. Stopped pre-populating the resolved-thumbnail-path map and allocating `ValueNotifier`s for every media record at startup. Paths/notifiers are now resolved as requested batches need them.
3. Corrected batch completion bookkeeping so a failed/null thumbnail result is not marked completed. A batch with failures remains retryable instead of being permanently marked loaded.
4. Made queue eviction update batch bookkeeping, preventing a batch from remaining permanently in-flight after its queued work is evicted during fast scrolling.
5. Added disposed-state guards so pending cache scans/download callbacks don't continue updating thumbnail state after the manager is disposed.
6. Changed the scroll listener to request the current batch once per batch and trigger midpoint prefetch once per batch, instead of repeatedly requesting after the threshold is crossed.

## Validation status
- Reviewed the modified code and compared it with the uploaded source.
- `flutter analyze`, tests, and device profiling were **not run** because Flutter/Dart SDK executables are unavailable in this environment.
- Please run `dart format` on the two modified Dart files, then `flutter analyze` and a profile-mode scroll test on the target Android device before treating this as verified.

## Scope intentionally unchanged
No new features, UI redesign, authentication, Telegram upload, viewer, or navigation behavior was intentionally changed. This is a narrow Phase 1 performance/reliability pass; it does not yet implement Phase 2 gallery pagination.
