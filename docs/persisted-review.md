# Persisted review questions

Review progress belongs to a local user, query, and sense. Reimporting a dossier
updates its content without resetting earned stages, attempt counts, or learning
timestamps. A content update is not an automatic relearning policy.

An unanswered question has a narrower lifetime. Its displayed content and answer
must still match the dictionary when the answer is recorded. SQLite schema version
4 stores a `content_fingerprint` alongside each question's choices and correct
index. This is a SHA-256 hash of a versioned JSON representation containing:

- The target ID, learning stage, and normalized review language.
- The target word (also used for pronunciation), part of speech, and that
  language's correct meaning, with answer whitespace normalized.
- For a context question, its English example and highlighted target form.
- All four saved choice strings in order and the saved correct index.

An independent question does not display the example. Changes to its example do
not invalidate that question. Unused translations, other language meanings,
attempt counters, and the dossier's global content revision are also excluded.
Changing a displayed dependency invalidates the unanswered question even when the
correct option's text stays the same.

Distractors are frozen text, not references to live dictionary entries. Editing
another word or replacing an external candidate pool does not change the choices
or correct index of a saved question. The complete frozen choices are included
in its fingerprint. Candidate selection's existing language and duplicate checks
still apply when generating a new question.

## Transaction boundaries

Restoring a saved question reads the current target and snapshot in one SQLite
transaction. Generating a new question may load candidates outside a transaction;
the insertion transaction then rereads the session position and the target's
content dependencies. If the content changed while candidates loaded, preparation
reports a changed question instead of saving the obsolete one or skipping the
target. Another valid snapshot already saved for that position wins.

Submitting an answer checks the active session position, saved choices/index,
request content fingerprint, and current target fingerprint in the same
transaction as the progress, attempt, and session updates. A stale request changes
none of those records. A duplicate submission at an already advanced position
also changes none of them. If an answer commits before an import, its earned
progress is retained by that later import.

`ReviewQuestionChanged` asks the review page to prepare its current position
again. A failure during this preparation uses the existing Retry state. A
temporary database failure is propagated separately; it is not evidence that a
question or session contains invalid data. Session retirement for invalid data
only follows a failure to decode the stored session payload.

## Existing databases and verification

The schema 3 to 4 migration adds a nullable column without changing progress,
attempts, or session positions. A legacy NULL fingerprint cannot establish what
content the old question tested. The question is rebuilt from current content
when requested; the migration does not backfill an invented fingerprint onto
its old choices. Malformed or stale snapshots are likewise rebuilt. Only the
question snapshot is discarded, and database read/delete failures remain errors.

`test/persisted_review_content_test.dart` uses fresh file-backed SQLite databases,
closes and reopens them, exercises the schema upgrade, injects one-shot read and
retirement failures, interrupts an attempt write with a SQLite abort trigger, and
holds candidate loading across an import. Widget regressions cover updating a
visible question and retrying after a preparation failure.

These checks establish application-level snapshot identity and transaction
behavior. They do not simulate a power cut or establish filesystem durability on
every device. The fingerprint is a consistency check, not authentication against
a party able to rewrite the local database.
