# Changelog

## 0.1.2

- Give each media playback its own player and keep native ownership separate
  from UI completion. Old events and page exits cannot cancel a newer request.
- Bound each native call to eight seconds. An ambiguous timeout disables audio
  for the application session, immediately attempts to stop the captured source,
  and observes late results for cleanup. Learning and answer submission remain
  available with a text status explaining that audio is unavailable.
- Disable unused native position polling and test the actual service against
  controlled player and system-speech platform calls, including delayed failures.
- Document system-speech callback limitations and best-effort native cleanup.
  These tests do not establish physical-device silence or a total exit deadline.

## 0.1.1

- Keep imported content and learning progress when the home screen refreshes.
  Bundled samples now fill missing meanings without overwriting existing records.
- Accept either one S6 entry or an array. Validate the entire file before writing,
  enforcing the actual byte limit and rejecting entries without learning content.
- Preserve committed import counts when storage or a subsequent refresh fails.
  A successful retry clears the loading error without losing the import result.
- Apply one speech-download deadline across headers and body. Timeout aborts the
  request, cancels body reading and closes the client owned by that request.
- Validate on Flutter 3.44.0 and 3.47.2. The committed dependency lock matches the
  minimum Flutter version; newer SDKs resolve their own required framework pins.
- Publish the Android debug build as a CI artifact for development verification.

## 0.1.0

- Initial community learning core, original sample words and S6 imports.
- Local SQLite progress, review preparation, pronunciation and optional speech gateway.
