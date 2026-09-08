# WordAI Community

[简体中文](README.zh-CN.md)

An offline vocabulary-learning app built with Flutter and SQLite. Learn and review
words without an account, subscription or hosted service.

This community edition contains the learning and flash-card core from WordAI,
adapted to run independently with a clean Git history. The production app's
accounts, cloud sync, AI lookup, billing and private content are not included.

## Run locally

Use Flutter 3.44 or a newer stable release with a compatible Dart SDK (3.6+).

```sh
flutter pub get
flutter run
```

Android, iOS and macOS projects are included. Device signing for iOS/macOS is your
own configuration; no signing team, certificate or production backend is bundled.
The [CI workflow](.github/workflows/checks.yml) runs analysis, tests and an Android
debug build. Analysis and tests run on Flutter 3.44.0 and 3.47.2; the latter also
produces a downloadable debug APK in the Actions run. This is a development build,
not a signed store release. Platform support beyond those checks should be verified on the target device.

## What the app does

- Stores learning records and per-meaning progress in local SQLite.
- Reviews example sentences and independent word recognition as separate stages.
- Selects distractors from all imported meanings, so a small current review queue
  does not incorrectly appear to be fully learned.
- Plays pronunciation with local caching, optional self-hosted speech, and device
  speech fallback when available.
- Includes 12 original example words and imports user-supplied S6 JSON entries.
- Provides English, Simplified Chinese and Traditional Chinese review interfaces,
  with support for reduced motion.

## Read the engineering

| Problem | Implementation | Regression tests |
|---|---|---|
| Persist meaning-level learning progress | [learning_repository.dart](lib/services/learning_repository.dart) | [learning_repository_test.dart](test/learning_repository_test.dart) |
| Preserve imported content across refreshes | [dictionary_import.dart](lib/services/dictionary_import.dart) | [home import](test/home_import_widget_test.dart), [dictionary validation](test/dictionary_import_test.dart) |
| Bound a slow speech download | [community_gateway.dart](lib/services/community_gateway.dart) | [gateway lifecycle](test/community_gateway_test.dart) |
| Prepare a usable review from available content | [review_preparation.dart](lib/services/review_preparation.dart) | [review_preparation_test.dart](test/review_preparation_test.dart) |
| Coordinate pronunciation during review | [review_pronunciation.dart](lib/services/review_pronunciation.dart) | [review_pronunciation_test.dart](test/review_pronunciation_test.dart), [playback arbitration](test/tts_playback_arbiter_test.dart) |
| Keep review states explicit | [review availability tests](test/review_availability_widget_test.dart) | [loading-state tests](test/review_loading_widget_test.dart) |

```sh
flutter analyze
flutter test
python3 scripts/check_public_tree.py
```

## Import words

Choose **Import JSON** on the home screen. A file may contain one entry or an array
using the S6 schema in [wordai_dossier.dart](lib/services/wordai_dossier.dart).
See [examples/words.json](examples/words.json).

Files are validated before writes, with a limit of 10 MiB actually read and 20,000
entries. Empty files, empty arrays and lookup abstentions are not importable.
Reimporting an entry updates its content while preserving learning progress. A
storage failure may leave earlier entries imported; retrying is supported. The
import is not represented as an all-or-nothing database transaction.

Refreshing the home screen seeds only missing sample meanings. It does not
overwrite an imported replacement or reset its learning state.

Import only content you have permission to use. Production third-party dictionaries
and audio collections are not distributed here.

## Optional speech gateway

The default configuration makes no network requests to a hosted speech service.
Device speech availability depends on the installed system voices. To fetch audio,
implement the [gateway protocol](docs/speech-gateway.md) and explicitly configure it:

```sh
flutter run --dart-define=WORD_AI_API_BASE_URL=https://your-gateway.example
```

The URL is compiled into the client and must contain no secret. Provider keys
belong on the server. Requested speech text is sent to your configured gateway;
a gateway failure does not stop local learning.

## Scope and contributions

Source code is Apache-2.0 licensed, including commercial use subject to the license
and third-party terms. WordAI names and artwork do not grant trademark rights.
Community-edition history and usage must not be confused with the private product.

[Open-source boundary](docs/open-source-scope.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)
