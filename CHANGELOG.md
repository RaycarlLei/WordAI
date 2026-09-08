# Changelog

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
