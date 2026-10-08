import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/learning_backup.dart';
import 'package:word_a_i/services/word_book_repository.dart';
import 'package:word_a_i/services/wordai_dossier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LearningRepository learning;
  late WordBookRepository books;
  late DateTime now;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await LearningRepository.createSchema(db);
    learning = LearningRepository.forTesting(db);
    now = DateTime.utc(2026, 1, 1);
    books = WordBookRepository(learning, clock: () => now);
    await learning.seedEmptyProfile('local', sampleWords());
  });
  tearDown(() => db.close());

  test('local CRUD, normalized membership, scoped review and system rules',
      () async {
    final id = await books.create('Study');
    await books.rename(id, 'Travel');
    await books.add(id, [' Cat ', 'cat', 'river']);
    final book = (await books.books()).singleWhere((b) => b.id == id);
    expect(book.name, 'Travel');
    expect(book.words, ['cat', 'river']);
    final session =
        (await learning.createSession('local', queries: book.words))!;
    for (final target in session.targetIds) {
      expect(book.words, contains((await learning.targetById(target))!.query));
    }
    final resumed = await learning.resumeScopedSession('local', book.words);
    expect(resumed!.id, session.id);
    expect((await books.books()).singleWhere((b) => b.id == 'default').words,
        hasLength(12));
    await expectLater(books.delete('default'), throwsStateError);
    await expectLater(books.delete('learned'), throwsStateError);
    await expectLater(books.rename('learned', 'Changed'), throwsStateError);
    await expectLater(books.add(id, ['not-imported']), throwsStateError);
    expect((await books.books()).singleWhere((b) => b.id == id).words,
        ['cat', 'river']);
  });

  test('all senses must be learned, manual removal survives refresh and backup',
      () async {
    await db.update('learning_progress',
        {'stage': 2, 'learned_at': now.millisecondsSinceEpoch - 1},
        where: 'query = ?', whereArgs: ['cat']);
    expect((await books.books()).singleWhere((b) => b.id == 'learned').words,
        ['cat']);
    await books.remove('learned', ['cat']);
    expect((await books.books()).singleWhere((b) => b.id == 'learned').words,
        isEmpty);
    final backup = await LearningBackupService(learning).capture();
    await books.add('learned', ['cat']);
    await LearningBackupService(learning).restore(backup);
    expect((await books.books()).singleWhere((b) => b.id == 'learned').words,
        isEmpty);
    await db.update(
        'learning_progress', {'learned_at': now.millisecondsSinceEpoch + 1},
        where: 'query = ?', whereArgs: ['cat']);
    expect((await books.books()).singleWhere((b) => b.id == 'learned').words,
        ['cat']);
    // A newly imported meaning makes the word incomplete again; existing
    // manual/automatic membership is retained, new automatic admission waits.
    final original =
        (await db.query('learning_progress', where: "query = 'river'")).single;
    await db.insert('learning_progress',
        {...original, 'target_id': 'extra', 'sense_id': 'extra', 'stage': 0});
    await db.update('learning_progress', {'stage': 2},
        where: "query = 'river' AND sense_id != 'extra'");
    expect((await books.books()).singleWhere((b) => b.id == 'learned').words,
        isNot(contains('river')));
  });

  test(
      'trash restoration uses identity, merges members and expires at exactly 7 days',
      () async {
    final id = await books.create('Same');
    await books.add(id, ['cat', 'river']);
    await books.delete(id);
    final entry = (await books.trash()).single;
    final other = await books.create('Same');
    await books.restore(entry.id);
    expect((await books.books()).where((b) => b.name == 'Same'), hasLength(2));
    expect(
        (await books.books()).singleWhere((b) => b.id == other).words, isEmpty);
    await books.remove(id, ['cat']);
    final removed = (await books.trash()).single;
    await books.add(id, ['cat']);
    await books.restore(removed.id);
    expect((await books.books()).singleWhere((b) => b.id == id).words,
        ['cat', 'river']);
    await books.delete('unfamiliar');
    expect((await books.books()).any((b) => b.id == 'unfamiliar'), isFalse);
    await books.restore((await books.trash()).single.id);
    expect((await books.books()).any((b) => b.id == 'unfamiliar'), isTrue);
    await books.delete(id);
    final expiring = (await books.trash()).single;
    now = now.add(WordBookRepository.retention);
    await expectLater(books.restore(expiring.id), throwsStateError);
    expect(await books.trash(), isEmpty);
  });

  test('failed trash insert or failed restore rolls back every mutation',
      () async {
    final id = await books.create('Protected');
    await books.add(id, ['cat']);
    await db.execute(
        "CREATE TRIGGER reject_trash BEFORE INSERT ON word_book_trash BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
    await expectLater(books.delete(id), throwsA(isA<DatabaseException>()));
    await expectLater(
        books.remove(id, ['cat']), throwsA(isA<DatabaseException>()));
    expect((await books.books()).singleWhere((b) => b.id == id).words, ['cat']);
    await db.execute('DROP TRIGGER reject_trash');
    await books.delete(id);
    final entry = (await books.trash()).single;
    await db.execute(
        "CREATE TRIGGER reject_member BEFORE INSERT ON word_book_members BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
    await expectLater(
        books.restore(entry.id), throwsA(isA<DatabaseException>()));
    expect(await db.query('word_books', where: 'id = ?', whereArgs: [id]),
        isEmpty);
    expect(await books.trash(), hasLength(1));
    await db.execute('DROP TRIGGER reject_member');
    await books.permanentlyDelete(entry.id);
    expect(await books.trash(), isEmpty);
  });

  test(
      'v2 backup includes books, members, trash and removals; v1 initializes defaults',
      () async {
    final id = await books.create('Trip');
    await books.add(id, ['cat', 'river']);
    await books.remove(id, ['cat']);
    final service = LearningBackupService(learning);
    final backup = await service.capture();
    final json =
        jsonDecode(utf8.decode(backup.toBytes())) as Map<String, dynamic>;
    expect(json['version'], 2);
    await books.delete(id);
    await service
        .restore(await readLearningBackup(Stream.value(backup.toBytes())));
    expect(
        (await books.books()).singleWhere((b) => b.id == id).words, ['river']);
    await books.restore((await books.trash()).single.id);
    expect((await books.books()).singleWhere((b) => b.id == id).words,
        ['cat', 'river']);
    final old = Map<String, dynamic>.from(json)..['version'] = 1;
    for (final key in [
      'word_books',
      'word_book_members',
      'word_book_removals',
      'word_book_trash'
    ]) {
      old.remove(key);
    }
    await service.restore(
        await readLearningBackup(Stream.value(utf8.encode(jsonEncode(old)))));
    expect((await books.books()).map((b) => b.id).toSet(),
        {'default', 'learned', 'unfamiliar'});
    expect((await books.books()).singleWhere((b) => b.id == 'default').words,
        hasLength(12));
    final invalid = Map<String, dynamic>.from(json)..['version'] = 3;
    await expectLater(
        readLearningBackup(Stream.value(utf8.encode(jsonEncode(invalid)))),
        throwsA(isA<LearningBackupException>()));
    (json['word_book_members'] as List).first['book_id'] = 'missing';
    await expectLater(
        readLearningBackup(Stream.value(utf8.encode(jsonEncode(json)))),
        throwsA(isA<LearningBackupException>()));
  });

  test(
      'reimporting capitalized content does not revive removed default membership',
      () async {
    await books.remove('default', ['cat']);
    final edited = sampleWords().first.toJson()..['query'] = 'CAT';
    await learning.registerDossier(
        'local', WordAiDossier.fromJson(edited, expectedQuery: 'CAT'));
    expect((await books.books()).singleWhere((b) => b.id == 'default').words,
        isNot(contains('cat')));
    expect((await LearningBackupService(learning).capture()).progressCount, 12);
  });

  test('a correct independent answer admits the word in the same commit',
      () async {
    await db.update('learning_progress', {'stage': 1}, where: "query = 'cat'");
    final session = (await learning.createSession('local', queries: ['cat']))!;
    final question = (await learning.buildQuestion(session, 'en'))!;
    await learning.recordAnswer(
        uid: 'local',
        session: session,
        question: question,
        selectedIndex: question.correctIndex,
        latencyMs: 10,
        activeMs: 10);
    expect(
        (await db.query('word_book_members', where: "book_id = 'learned'"))
            .single['query'],
        'cat');
  });

  test('disk v4 upgrade preserves vocabulary and initializes word books',
      () async {
    final dir = await Directory.systemTemp.createTemp('wordbooks-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/learning.db';
    var disk = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 4, onCreate: LearningRepository.createSchema));
    await LearningRepository.forTesting(disk)
        .seedEmptyProfile('local', sampleWords());
    for (final table in [
      'word_book_members',
      'word_book_removals',
      'word_book_trash',
      'word_books'
    ]) {
      await disk.execute('DROP TABLE $table');
    }
    await disk.close();
    disk = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 5, onUpgrade: LearningRepository.upgradeSchema));
    final local = WordBookRepository(LearningRepository.forTesting(disk));
    expect((await local.books()).singleWhere((b) => b.id == 'default').words,
        hasLength(12));
    await local.rename(await local.create('Persistent'), 'Saved');
    await disk.close();
    disk = await databaseFactoryFfi.openDatabase(path);
    expect(
        (await WordBookRepository(LearningRepository.forTesting(disk)).books())
            .any((b) => b.name == 'Saved'),
        isTrue);
    await disk.close();
  });
}
