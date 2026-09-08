# Audio ownership and native failure boundaries

WordAI has one audio coordinator. A review owns its pending request and native
playback by source ID and request generation. Finishing the on-screen animation
does not release native ownership: leaving the review still requests a stop.
Review answers and saved progress do not depend on audio being available.

## What the Dart service enforces

- Every media utterance gets a fresh `AudioPlayer`. The old player must
  acknowledge stop and finish disposal before another backend may speak.
  Media events belong to that captured player and request; a retired player's
  completion or error cannot finish a new player or trigger system speech.
- Fresh media players disable the unused position updater before configuration.
  Speech has no timeline UI; native position polling would otherwise introduce
  plugin Futures outside the coordinator's error handling and disposal bounds.
- Device speech is created independently of media playback. Using local system
  speech does not allocate or wait for an unused media player.
- Each native operation has an eight-second Dart deadline. This covers player
  creation (awaited by its first configuration call), configuration, preparing
  a source, resume/speak, rate changes, stop and disposal. A sequence of successful
  calls can take more than eight seconds; this is a per-call bound. Downloads
  have the separate [gateway deadline](speech-gateway.md).
- Timeout does not cancel a native call. A timed-out call, rejected stop or
  failed disposal makes the coordinator permanently unavailable for that app
  session. Queued and future playback requests finish with an error; neither
  another media player nor system speech is started as a workaround.
- Late results and errors remain observed. A late result can request another
  bounded stop of its captured native owner. It cannot restore availability,
  update the current indicator, resume playback or create another backend.
- Entering the unavailable state immediately attempts a separate bounded stop,
  even if the original call never returns. That attempt is cleanup only; a
  later source/resume result still gets another stop attempt. Cleanup cannot
  restore availability and a stuck cleanup stop does not retry recursively.
- Disposal rejects new work immediately and performs bounded cleanup. A media
  handle with an outstanding native call is retained rather than treating
  `AudioPlayer.dispose()` as a way to kill that call. Logical disposal may finish
  while native cleanup remains unconfirmed. No successful return from Dart
  disposal promises acoustic silence.

An ordinary media error can fall back to device speech only after the old
player's stop and disposal have both succeeded. An uncertain stop cannot fall
back. The review shows an inline unavailable notice and remains usable; restart
the app before trying audio again. Playback's boolean result means the current
request was accepted, not that a speaker produced sound or the utterance finished.

## Limits of the locked plugins

The lockfile currently resolves `audioplayers` 6.8.1 and `flutter_tts` 4.2.5.
This implementation depends on their public behavior:

| Plugin boundary | Consequence |
| --- | --- |
| AudioPlayer routes native events by `playerId`, but not by source within one player. | Separate players provide an event boundary between media utterances. |
| AudioPlayer disposal calls stop/release before native disposal. | A hung stop can also hang disposal; neither method is a forced native termination API. |
| FlutterTts instances share the `flutter_tts` channel and native engine. Constructing one replaces the Dart handler. | Creating another FlutterTts is not independent engine isolation or timeout recovery. |
| FlutterTts forwards system completion/cancel/error events without an utterance ID. | A delayed event for system utterance A can still change the indicator for system utterance B. Backend checks prevent it affecting media; retained ownership ensures B can still be stopped. |
| Android/iOS system stop returns a plugin acknowledgement without propagating the native stop result. | Acknowledgement is the strongest available handoff signal, not proof of silence. |

Strict correlation between successive system utterances needs a native bridge
that returns an utterance ID and engine generation with each event. Switching
to `awaitSpeakCompletion` does not supply this: the locked plugin uses shared
completion state. WordAI does not claim this stronger guarantee.

## Verification and remaining device checks

[`tts_service_lifecycle_test.dart`](../test/tts_service_lifecycle_test.dart)
drives the actual TTSService, AudioPlayer wrapper, per-player platform event
streams and FlutterTts method channel. Gates control pending and late native
calls. It verifies cross-backend events, retired media instances, cancellation,
failed recovery, blocked source/resume/stop/dispose, queued callers and late
cleanup. These are host tests; they do not play audio.
The fixture returns unmodified AudioPlayers and rejects native position queries,
so it also verifies that production code disables the unused updater.

On Android and iOS devices, still verify audible stop/handoff, interruptions,
background/resume, rapid A-to-B system speech, missing voices and speaker/route
changes. In particular, measure whether native audio continues after a stop
acknowledgement or plugin failure. Host tests cannot establish acoustic silence
or the OS's resource-release behavior. No device result is claimed here.
