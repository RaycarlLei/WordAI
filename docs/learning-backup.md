# Learning backup and recovery

A learning backup saves the local review data needed to continue learning on
another installation: the stored meanings and examples used for review, earned
progress, session summaries, and answered-attempt history. It is a UTF-8 JSON
file with format `wordai-learning-backup`, version `2`, and profile `local`. Version 1 remains readable.

This is a logical database snapshot, not an archive of the original S6 dossiers.
The learning tables contain only the review fields extracted from those dossiers;
unused dossier sections cannot be reconstructed from a backup. Settings, speech
configuration, credentials, downloaded audio, cached distractors, and cloud sync
cursors are excluded. The file contains learning content and history in plaintext.
Choose a storage location appropriate for that content.

## Export and restore

Export reads all learning and word-book tables and checks the profile in one SQLite
transaction. It selects explicit columns, rather than copying the database file
or accepting every column a future schema might add. Export is read-only: it
does not retire an active session or clear cached questions. An invalid local
record or an oversized export fails the operation; rows are never silently
discarded to make a backup fit.

Restore first reads and validates the entire file without opening the database.
The preview shows its creation time and target, session, and attempt counts.
Confirm **Replace local learning data** only when this snapshot should replace
the current installation's learning data. A populated installation is supported;
restore does not require removing the starter vocabulary first. Export the
current data separately if it may still be needed.

The replacement transaction checks again that the database contains only the
`local` profile. Any other profile in progress, sessions, attempts, or sync state
causes rejection before deletion. In one transaction, restore removes old review
questions, attempts, sessions, progress and local sync state, then inserts the
validated progress, sessions and attempts in dependency order. An insertion
failure rolls back the transaction. A database or commit failure is reported
without exposing SQL diagnostics or learning content; reopen the app and inspect
the data before retrying if an IO failure leaves the outcome uncertain.

All imported `synced_at` values are absent and therefore become `NULL` in SQLite.
Already completed or exited sessions retain their stored history. An imported
`active` session becomes `exited`, with `exit_reason = restored_backup` and its
`ended_at` and `updated_at` set to the backup's creation time. Its earned progress,
answer history, counters and current index remain intact. Using the backup time
makes repeated restoration of the same file deterministic.

Saved question options are never exported or restored, including the unanswered
question in an active round. The next round gets a new session ID and prepares
new questions from the restored learning content. Session-specific distractor
caches cannot be selected by that new ID. Callers must keep learning and dictionary
import inactive from capture/restore start until completion; a transaction does
not cancel unrelated asynchronous UI work.

Restoring is replacement, not merging or synchronization. It does not reconcile
two independently advanced devices. The format does not authenticate a file's
author or prove learning achievements: identity hashes catch inconsistent links,
but anyone who edits a file can recalculate them. SQLite transaction tests are not
an Android power-loss, filesystem durability, or cloud-backup guarantee.

## Version 1 format

All root keys are required, and unknown keys are rejected:

| Root key | Value |
| --- | --- |
| `format` | `"wordai-learning-backup"` |
| `version` | Integer `1` |
| `profile` | `"local"` |
| `created_at_ms` | Nonnegative epoch milliseconds in the range below |
| `learning_progress` | 1–100,000 explicit progress rows |
| `review_sessions` | 0–100,000 explicit session rows |
| `review_attempts` | 0–500,000 explicit attempt rows |

An empty progress array is rejected to prevent accidental clearing. A backup
containing learning content but no sessions or attempts is valid. The 32 MiB file
limit applies independently of row limits and normally bounds large histories
first.

Each row requires exactly the following fields, including nullable fields:

```text
learning_progress:
  target_id, uid, lexeme_id, word, query, direction, sense_id,
  part_of_speech, definition_en, meaning_zh_hans, meaning_zh_hant,
  example_en, example_zh_hans, example_zh_hant, target_form, stage,
  context_passed_at, learned_at, learned_once, attempt_count,
  last_tested_at, content_version, updated_at

review_sessions:
  session_id, uid, started_at, ended_at, active_ms, target_count,
  completed_count, context_passed_count, new_learned_count,
  current_index, target_ids_json, status, exit_reason, updated_at

review_attempts:
  attempt_id, uid, session_id, target_id, test_type, correct,
  latency_ms, previous_stage, new_stage, created_at
```

`review_questions`, `learning_sync_state`, and every `synced_at` column are
intentionally outside the format. Each row's `uid` must be `local`. IDs are unique
within their table. Every selected target and every attempt target must exist in
progress. Every attempt must name an existing session which selected that target.

Progress identities follow the repository's existing UTF-8 SHA-256 encoding:

```text
lexeme_id = sha256(direction + "::" + query.trim().toLowerCase())
target_id = sha256("local::" + lexeme_id + "::" + sense_id)
```

Digests must use 64 lowercase hexadecimal characters. `direction` is `en_to_zh`
or `zh_to_en`. Query case and whitespace normalization uses Dart's existing
string operations; this format does not introduce a new Unicode normalization
scheme or rewrite content. Session and attempt IDs are nonblank strings of at
most 128 UTF-8 bytes; they need not be newly generated during restore.

## Bounds and validation

The input cap is **33,554,432 actual stream bytes (32 MiB)**, including whitespace.
File-picker size metadata is not trusted. Reading stops when the next chunk
would exceed the limit. UTF-8 must decode without malformed byte sequences;
JSON must be complete. Duplicate object keys, including escaped spellings of the
same key, are rejected before decoding can discard them. Nesting is limited to
eight containers. Unpaired UTF-16 surrogates in decoded field strings are rejected
before UTF-8 hashing or serialization can replace them.

| Field group | Accepted range |
| --- | --- |
| Creation, update, start, end and learning timestamps | Integer 0–8,640,000,000,000,000 ms, within Dart `DateTime`'s range |
| `context_passed_at`, `learned_at`, `last_tested_at`, `ended_at` | Timestamp above or `null` |
| `active_ms` | Integer 0–9,007,199,254,740,991 |
| Progress `attempt_count` and session counters | Integer 0–2,147,483,647 |
| Progress `stage` | Integer 0, 1 or 2 |
| `learned_once`, attempt `correct` | Integer 0 or 1, not JSON booleans |
| Attempt `latency_ms` | Integer 0–3,600,000 |
| Attempt `previous_stage` | 0 for `context`, 1 for `independent` |
| Attempt `new_stage` | `previous_stage + correct` |
| `target_ids_json` | String up to 4,096 UTF-8 bytes containing a JSON array of 1–20 distinct target hashes |
| `current_index` | Nonnegative integer no greater than the selected target count |
| `query` | Nonblank string, up to 2,048 UTF-8 bytes |
| `sense_id` | Nonblank string, up to 256 UTF-8 bytes |
| `content_version` | Nonblank string, up to 128 UTF-8 bytes |
| `exit_reason` | `null` or string up to 1,024 UTF-8 bytes |
| Remaining content strings | Up to 65,536 UTF-8 bytes each; empty strings are preserved |
| Session `status` | `active`, `completed` or `exited` |

Integer fields reject fractions, floating-point encodings such as `1.0`, numeric
strings and booleans. Timestamps need not be ordered: a device clock can change.
Historical session summaries and accumulated progress need not equal the
attempts present in this snapshot, and a summary's `target_count` need not equal
the stored selection length. Those values are preserved rather than recomputed.
The format validates references and answer transitions without treating a
history export as an independent proof of the user's score.

Export accounts for serialized row bytes while collecting a transaction snapshot
and uses bounded UTF-8 encoding for the final document. Import is a bounded,
in-memory operation, not streaming record-by-record insertion. The byte cap is
not a process heap cap; decoded strings, maps and SQLite driver buffers also use
memory.

## Verification

`flutter test test/learning_backup_test.dart` uses disposable, file-backed SQLite
databases. Coverage includes earned progress and active history across close and
reopen, a writer queued between snapshot reads, a real SQLite trigger that fails
after replacement has already begun, repeat restore, another profile, strict
schema and reference rejection, malformed and truncated input, duplicate JSON
keys and IDs, exact UTF-8 boundaries, input cancellation on overflow, and oversized
export without source changes. The trigger test compares all five tables after
reopening the database; atomicity is not inferred from an in-memory mock.

The [widget tests](../test/learning_backup_widget_test.dart) cover the explicit
replacement decision, cancellation, failed writes, disposal during asynchronous
work, restored vocabulary across home refreshes and reopening, and controls at
200% text size on a small screen. The [file adapter tests](../test/backup_files_test.dart)
check platform error redaction, overlapping requests and actual desktop file bytes.

## System file delivery

Android starts `ACTION_CREATE_DOCUMENT` with a JSON MIME type. Only the chosen
document URI is written; broad storage access is not requested. A single background
writer completes write, flush and close before reporting success. A 30-second
deadline bounds the caller's wait after selection. If a provider blocks, the UI
receives failure and the writer remains occupied until the provider returns;
retries cannot accumulate writer threads. Activity loss and late callbacks cannot
confirm a different pending request. A failure can leave a partial selected file,
which the app never deletes automatically.

iOS prepares one protected temporary file and presents the system document export
picker. The preparation wait is bounded; time spent choosing a destination is not.
Only the export delegate confirms success. Cancellation returns separately from
failure. The app removes its own temporary directory after completion or failure;
an abrupt process kill can leave it for the system to clean up later. A provider's
export confirmation does not establish that a remote cloud copy is synchronized.

Desktop uses `file_selector` to choose a destination and saves with `XFile.saveTo`.
Restore uses the platform open-file picker and validates its actual byte stream.
Neither path changes account credentials, requests cloud OAuth permissions, or
uploads to an application-managed service. Choosing a cloud-backed location in a
system picker is the user's storage choice.

[Android acceptance](../.github/workflows/android-backup.yml) runs on a fresh API
35 emulator with synthetic documents in a test-APK-only provider. It covers the
real system picker and native handler rather than a mocked Dart channel. It does
not establish behavior on physical devices, every document provider, or the full
Flutter-to-native restore flow. The [iOS simulator workflow](../.github/workflows/ios-build.yml)
checks Swift/plugin compilation without signing; it does not exercise the export
picker. Check each workflow's actual result for the commit being evaluated.

This feature cannot extract data from an inaccessible old installation. In
particular, an APK signed with another debug key normally cannot replace it in
place. Keep the old installation until its data has been backed up through a
compatible build or a separately verified recovery process. No production signing
material or user backup is distributed by this repository.

## Version 2 word-book extension

Version 2 requires four additional root arrays: `word_books`,
`word_book_members`, `word_book_removals` and `word_book_trash`. Every row uses
profile `local`; columns are explicitly listed in `word_book_schema.dart`.
The preview and byte/row limits apply before the replacement transaction.
System identities and kinds, membership identities, references to stored
queries, unique rows, seven-day expiry and bounded names are validated.
Unrecognized format versions or extra fields are rejected before any writes.

Restore replaces book membership, manual Learned-removal timestamps and trash
in the same transaction as learning data. Format 1 initializes Default, Learned
and Unfamiliar Words, placing restored vocabulary in Default. Format 2 preserves
book identity and original trash expiry: restoring does not restart seven days.
The next book read reconciles fully learned words, honoring manual removals.
The database upgrade from schema 4 to 5 preserves progress and unanswered rounds;
only explicit backup restoration closes unfinished rounds as described above.
