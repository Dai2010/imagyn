import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'models.dart';

class LocalStore {
  LocalStore._(this.root, this.db);
  final Directory root;
  final Database db;
  final _secure = const FlutterSecureStorage();
  int _sequence = 0;

  static Future<LocalStore> open() async {
    final root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'imagyn'),
    );
    await root.create(recursive: true);
    await Directory(p.join(root.path, 'assets')).create(recursive: true);
    if (Platform.isLinux || Platform.isWindows) {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
    }
    final db = await openDatabase(
      p.join(root.path, 'history.sqlite'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY, record TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, record TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE jobs (id TEXT PRIMARY KEY, state TEXT NOT NULL, record TEXT NOT NULL)',
        );
      },
    );
    return LocalStore._(root, db);
  }

  String newId() => '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  Future<String?> setting(String key) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) => db
      .insert('settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<ServiceConfig> config() async => ServiceConfig.fromJson(
    jsonDecode(await setting('service') ?? '{}') as Map<String, dynamic>,
  );
  Future<void> saveConfig(
    ServiceConfig config,
    String key,
    String imageKey,
  ) async {
    await _secure.write(key: 'api_key', value: key);
    await _secure.write(key: 'image_key', value: imageKey);
    await setSetting('service', jsonEncode(config.toJson()));
    await setSetting('onboardingVersion', '1');
  }

  Future<String> apiKey() async => await _secure.read(key: 'api_key') ?? '';
  Future<String> imageKey() async => await _secure.read(key: 'image_key') ?? '';

  Future<Asset> saveAsset(
    Uint8List bytes, {
    String prompt = '',
    String? parentId,
    Map<String, dynamic> parameters = const {},
  }) async {
    final id = newId();
    final mime = sniffMime(bytes);
    final ext = {
      'image/png': 'png',
      'image/jpeg': 'jpg',
      'image/webp': 'webp',
    }[mime]!;
    final relative = p.join('assets', '$id.$ext');
    final destination = File(p.join(root.path, relative));
    final temp = File('${destination.path}.partial');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(destination.path);
    final asset = Asset(
      id: id,
      path: relative,
      mime: mime,
      prompt: prompt,
      createdAt: DateTime.now(),
      parentId: parentId,
      parameters: parameters,
    );
    await db.insert('assets', {'id': id, 'record': jsonEncode(asset.toJson())});
    return asset;
  }

  File file(Asset asset) => File(p.join(root.path, asset.path));
  Future<List<Asset>> assets() async =>
      (await db.query('assets', orderBy: 'id DESC'))
          .map(
            (r) => Asset.fromJson(
              jsonDecode(r['record'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();
  Future<Asset?> asset(String id) async {
    final rows = await db.query('assets', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty
        ? null
        : Asset.fromJson(
            jsonDecode(rows.first['record'] as String) as Map<String, dynamic>,
          );
  }

  Future<void> addMessage(String session, ChatEntry entry) => db
      .insert('messages', {
        'session': session,
        'record': jsonEncode(entry.toJson()),
      })
      .then((_) {});
  Future<List<ChatEntry>> messages(String session) async =>
      (await db.query(
            'messages',
            where: 'session = ?',
            whereArgs: [session],
            orderBy: 'id ASC',
          ))
          .map(
            (r) => ChatEntry.fromJson(
              jsonDecode(r['record'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();
  Future<void> job(String id, String state, Map<String, dynamic> record) => db
      .insert('jobs', {
        'id': id,
        'state': state,
        'record': jsonEncode(record),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<List<ImageJob>> jobs() async =>
      (await db.query(
            'jobs',
            where: 'state != ?',
            whereArgs: ['complete'],
            orderBy: 'id DESC',
          ))
          .map(
            (row) => ImageJob(
              row['id'] as String,
              row['state'] as String,
              jsonDecode(row['record'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();

  Future<void> dismissJob(String id) => db
      .delete(
        'jobs',
        where: 'id = ? AND state != ?',
        whereArgs: [id, 'submitting'],
      )
      .then((_) {});

  /// Marks jobs that were still being submitted when the process died as
  /// unknown, and reports how many there were so the caller can warn the user
  /// before another paid request is allowed.
  Future<int> recoverJobs() => db.update(
    'jobs',
    {'state': 'unknown'},
    where: 'state = ?',
    whereArgs: ['submitting'],
  );
}

String sniffMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  throw const FormatException('invalidImage');
}
