import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'learning_repository.dart';
import 'word_book_schema.dart';

class LocalWordBook {
  const LocalWordBook(this.id, this.name, this.kind, this.words);
  final String id, name, kind;
  final List<String> words;
  bool get permanent => kind == 'default' || kind == 'learned';
}

class LocalTrashEntry {
  LocalTrashEntry(Map<String, Object?> row)
      : id = row['id'] as String,
        name = row['name'] as String,
        kind = row['kind'] as String,
        bookId = row['book_id'] as String,
        expiresAt = row['expires_at'] as int,
        words =
            (jsonDecode(row['queries_json'] as String) as List).cast<String>();
  final String id, name, kind, bookId;
  final int expiresAt;
  final List<String> words;
}

/// One local SQLite profile. Every destructive operation and its recovery
/// record are committed together; no account or network service is involved.
class WordBookRepository {
  WordBookRepository(this.learning, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;
  final LearningRepository learning;
  final DateTime Function() clock;
  static const retention = Duration(days: 7);
  static const _uuid = Uuid();

  Future<List<LocalWordBook>> books() async {
    final db = await learning.database;
    return db.transaction((txn) async {
      await _reconcile(txn);
      final rows = await txn.query('word_books', orderBy: 'created_at, id');
      final result = <LocalWordBook>[];
      for (final row in rows) {
        final members = await txn.query('word_book_members',
            where: 'book_id = ?', whereArgs: [row['id']], orderBy: 'query');
        result.add(LocalWordBook(
            row['id'] as String,
            row['name'] as String,
            row['kind'] as String,
            members.map((r) => r['query'] as String).toList()));
      }
      return result;
    });
  }

  String _name(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 128) {
      throw ArgumentError('Use a name of 1–128 characters.');
    }
    return trimmed;
  }

  Future<String> create(String name) async {
    final id = _uuid.v4();
    await (await learning.database).insert('word_books', {
      'id': id,
      'uid': 'local',
      'name': _name(name),
      'kind': 'custom',
      'created_at': clock().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<Map<String, Object?>> _book(DatabaseExecutor db, String id) async {
    final rows = await db.query('word_books',
        where: 'id = ? AND uid = ?', whereArgs: [id, 'local']);
    if (rows.isEmpty) {
      throw StateError('This word book is no longer available.');
    }
    return rows.single;
  }

  Future<void> rename(String id, String name) async {
    final db = await learning.database;
    await db.transaction((txn) async {
      if ((await _book(txn, id))['kind'] != 'custom') {
        throw StateError('System books cannot be renamed.');
      }
      await txn.update('word_books', {'name': _name(name)},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> _add(
      DatabaseExecutor db, String id, Iterable<String> words) async {
    await _book(db, id);
    for (final word in words.toSet()) {
      final query = word.trim().toLowerCase();
      final present = await db.query('learning_progress',
          columns: ['target_id'],
          where: 'uid = ? AND LOWER(TRIM(query)) = ?',
          whereArgs: ['local', query],
          limit: 1);
      if (present.isEmpty) {
        throw StateError('Import this word before adding it.');
      }
      await db.insert('word_book_members',
          {'id': '$id:$query', 'uid': 'local', 'book_id': id, 'query': query},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      if (id == 'learned') {
        await db
            .delete('word_book_removals', where: 'id = ?', whereArgs: [query]);
        await db.delete('word_book_members',
            where: 'book_id = ? AND query = ?',
            whereArgs: ['unfamiliar', query]);
      }
    }
  }

  Future<void> add(String id, Iterable<String> words) async {
    await (await learning.database).transaction((txn) => _add(txn, id, words));
  }

  Future<void> remove(String id, Iterable<String> words) async {
    final db = await learning.database;
    await db.transaction((txn) async {
      final book = await _book(txn, id);
      final members = await txn
          .query('word_book_members', where: 'book_id = ?', whereArgs: [id]);
      final requested = words.map((w) => w.trim().toLowerCase()).toSet();
      final removing = members
          .map((r) => r['query'] as String)
          .where(requested.contains)
          .toList();
      if (removing.isEmpty) return;
      await _saveTrash(txn, book, 'words', removing);
      for (final word in removing) {
        if (id == 'learned') {
          await txn.insert(
              'word_book_removals',
              {
                'id': word,
                'uid': 'local',
                'removed_at': clock().millisecondsSinceEpoch
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.delete('word_book_members',
            where: 'book_id = ? AND query = ?', whereArgs: [id, word]);
      }
    });
  }

  Future<void> _saveTrash(DatabaseExecutor db, Map<String, Object?> book,
      String kind, List<String> words) async {
    final now = clock().millisecondsSinceEpoch;
    await db.insert('word_book_trash', {
      'id': _uuid.v4(),
      'uid': 'local',
      'book_id': book['id'],
      'name': book['name'],
      'kind': kind,
      'queries_json': jsonEncode(words),
      'deleted_at': now,
      'expires_at': now + retention.inMilliseconds
    });
  }

  Future<void> delete(String id) async {
    await (await learning.database).transaction((txn) async {
      final book = await _book(txn, id);
      if (book['kind'] == 'default' || book['kind'] == 'learned') {
        throw StateError('This word book cannot be deleted.');
      }
      final words = await txn
          .query('word_book_members', where: 'book_id = ?', whereArgs: [id]);
      await _saveTrash(
          txn, book, 'book', words.map((r) => r['query'] as String).toList());
      await txn
          .delete('word_book_members', where: 'book_id = ?', whereArgs: [id]);
      await txn.delete('word_books', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<LocalTrashEntry>> trash() async {
    final db = await learning.database;
    return db.transaction((txn) async {
      await txn.delete('word_book_trash',
          where: 'expires_at <= ?',
          whereArgs: [clock().millisecondsSinceEpoch]);
      return (await txn.query('word_book_trash',
              orderBy: 'deleted_at DESC, id'))
          .map(LocalTrashEntry.new)
          .toList();
    });
  }

  Future<void> restore(String trashId) async {
    await (await learning.database).transaction((txn) async {
      final rows = await txn.query('word_book_trash',
          where: 'id = ? AND expires_at > ?',
          whereArgs: [trashId, clock().millisecondsSinceEpoch]);
      if (rows.isEmpty) {
        throw StateError('This item has expired or was already restored.');
      }
      final row = rows.single;
      final id = row['book_id'] as String;
      final existing =
          await txn.query('word_books', where: 'id = ?', whereArgs: [id]);
      if (existing.isEmpty) {
        // Same identity, even if a newer book has the same display name.
        await txn.insert('word_books', {
          'id': id,
          'uid': 'local',
          'name': row['name'],
          'kind': id == 'unfamiliar' ? 'unfamiliar' : 'custom',
          'created_at': row['deleted_at']
        });
      }
      await _add(txn, id,
          (jsonDecode(row['queries_json'] as String) as List).cast<String>());
      await txn
          .delete('word_book_trash', where: 'id = ?', whereArgs: [trashId]);
    });
  }

  Future<void> permanentlyDelete(String trashId) async {
    await (await learning.database)
        .delete('word_book_trash', where: 'id = ?', whereArgs: [trashId]);
  }

  Future<void> _reconcile(DatabaseExecutor db) => reconcileLearnedBooks(db);
}
