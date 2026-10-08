import 'package:sqflite/sqflite.dart';

const wordBookFields = <String, List<String>>{
  'word_books': ['id', 'uid', 'name', 'kind', 'created_at'],
  'word_book_members': ['id', 'uid', 'book_id', 'query'],
  'word_book_removals': ['id', 'uid', 'removed_at'],
  'word_book_trash': [
    'id',
    'uid',
    'book_id',
    'name',
    'kind',
    'queries_json',
    'deleted_at',
    'expires_at'
  ],
};

Future<void> createWordBookSchema(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS word_books (
    id TEXT PRIMARY KEY, uid TEXT NOT NULL, name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('default','learned','unfamiliar','custom')),
    created_at INTEGER NOT NULL)''');
  await db.execute('''CREATE TABLE IF NOT EXISTS word_book_members (
    id TEXT PRIMARY KEY, uid TEXT NOT NULL, book_id TEXT NOT NULL,
    query TEXT NOT NULL, UNIQUE(book_id, query),
    FOREIGN KEY(book_id) REFERENCES word_books(id) ON DELETE CASCADE)''');
  await db.execute('''CREATE TABLE IF NOT EXISTS word_book_removals (
    id TEXT PRIMARY KEY, uid TEXT NOT NULL, removed_at INTEGER NOT NULL)''');
  await db.execute('''CREATE TABLE IF NOT EXISTS word_book_trash (
    id TEXT PRIMARY KEY, uid TEXT NOT NULL, book_id TEXT NOT NULL,
    name TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('book','words')),
    queries_json TEXT NOT NULL, deleted_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK(expires_at > deleted_at))''');
}

Future<void> initializeWordBooks(DatabaseExecutor db) async {
  for (final kind in ['default', 'learned', 'unfamiliar']) {
    await db.insert(
        'word_books',
        {
          'id': kind,
          'uid': 'local',
          'name': kind,
          'kind': kind,
          'created_at': 0
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await db
      .execute('''INSERT OR IGNORE INTO word_book_members(id,uid,book_id,query)
    SELECT 'default:' || LOWER(TRIM(query)), 'local', 'default', LOWER(TRIM(query))
    FROM learning_progress WHERE uid = 'local' GROUP BY LOWER(TRIM(query))''');
}

Future<void> reconcileLearnedBooks(DatabaseExecutor db) async {
  await db
      .execute("""INSERT OR IGNORE INTO word_book_members(id,uid,book_id,query)
    SELECT 'learned:' || query, 'local', 'learned', query FROM (
      SELECT LOWER(TRIM(query)) AS query, MAX(learned_at) AS learned_at
      FROM learning_progress WHERE uid = 'local'
      GROUP BY LOWER(TRIM(query)) HAVING MIN(stage) = 2
    ) AS complete WHERE NOT EXISTS (
      SELECT 1 FROM word_book_removals AS removed
      WHERE removed.id = complete.query
        AND removed.removed_at >= COALESCE(complete.learned_at,0))""");
  await db.execute("""DELETE FROM word_book_removals WHERE id IN (
    SELECT query FROM word_book_members WHERE book_id = 'learned')""");
  await db.execute("""DELETE FROM word_book_members WHERE book_id = 'unfamiliar'
    AND query IN (SELECT query FROM word_book_members WHERE book_id = 'learned')""");
}
