import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class LocalStore {
  final Database db;
  LocalStore(this.db);

  static Future<LocalStore> open({String? databasePath}) async {
    final db = await openDatabase(
      databasePath ?? path.join(await getDatabasesPath(), 'ecopulse.db'),
      version: 1,
      onCreate: (database, version) async {
        await database.execute(
          'CREATE TABLE pending(id TEXT PRIMARY KEY, user_id TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, error TEXT)',
        );
        await database.execute(
          'CREATE TABLE cache(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
    );
    await db.update(
      'pending',
      {'state': 'PENDING'},
      where: 'state = ?',
      whereArgs: ['SYNCING'],
    );
    return LocalStore(db);
  }

  Future<String> deviceId() async {
    final existing = await cached('device_id');
    if (existing != null) return existing as String;
    final value = const Uuid().v4();
    await saveCache('device_id', value);
    return value;
  }

  Future<void> enqueue(String userId, Map<String, dynamic> report) async {
    await db.insert('pending', {
      'id': report['id'],
      'user_id': userId,
      'payload': jsonEncode(report),
      'state': 'PENDING',
    });
  }

  Future<List<Map<String, Object?>>> pending(String userId) => db.query(
    'pending',
    where: 'user_id = ?',
    whereArgs: [userId],
    orderBy: 'rowid DESC',
  );
  Future<void> state(String id, String state, {String? error}) async {
    await db.update(
      'pending',
      {'state': state, 'error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveCache(String key, dynamic value) async {
    await db.insert('cache', {
      'key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<dynamic> cached(String key) async {
    final rows = await db.query('cache', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }
}
