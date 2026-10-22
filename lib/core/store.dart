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
    await Directory(p.join(root.path, 'decks')).create(recursive: true);
    if (Platform.isLinux || Platform.isWindows) {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
    }
    final db = await openDatabase(
      p.join(root.path, 'history.sqlite'),
      version: 2,
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
        await db.execute(
          'CREATE TABLE decks (id TEXT PRIMARY KEY, session TEXT NOT NULL, record TEXT NOT NULL)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE decks (id TEXT PRIMARY KEY, session TEXT NOT NULL, record TEXT NOT NULL)',
          );
        }
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
    String videoKey,
  ) async {
    await _secure.write(key: 'api_key', value: key);
    await _secure.write(key: 'image_key', value: imageKey);
    await _secure.write(key: 'video_key', value: videoKey);
    await setSetting('service', jsonEncode(config.toJson()));
    await setSetting('onboardingVersion', '1');
  }

  Future<String> apiKey() async => await _secure.read(key: 'api_key') ?? '';
  Future<String> imageKey() async => await _secure.read(key: 'image_key') ?? '';
  Future<String> videoKey() async => await _secure.read(key: 'video_key') ?? '';

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

  /// Clips go next to the pictures so one directory holds everything the app
  /// made, but they are kept as `video/mp4` rows: the Gallery filters on the
  /// mime type and never tries to decode one as an image.
  Future<Asset> saveVideo(
    Uint8List bytes, {
    String prompt = '',
    Map<String, dynamic> parameters = const {},
  }) async {
    final id = newId();
    final relative = p.join('assets', '$id.mp4');
    final destination = File(p.join(root.path, relative));
    final temp = File('${destination.path}.partial');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(destination.path);
    final asset = Asset(
      id: id,
      path: relative,
      mime: 'video/mp4',
      prompt: prompt,
      createdAt: DateTime.now(),
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

  /// Removes one saved image: the row the Gallery reads and the file on disk.
  /// A file that is already missing is not an error.
  Future<void> deleteAsset(String id) async {
    final saved = await asset(id);
    if (saved != null) {
      final target = file(saved);
      try {
        await target.delete();
      } on FileSystemException catch (error) {
        // Only "already gone" is acceptable; a permission or lock failure must
        // reach the caller instead of leaving a row pointing at an orphan.
        if (error.osError?.errorCode != 2) rethrow;
      }
    }
    await db.delete('assets', where: 'id = ?', whereArgs: [id]);
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

  /// Removes one job record. A submission that is still running is stopped by
  /// the caller first; the record itself is always deletable.
  Future<void> deleteJob(String id) =>
      db.delete('jobs', where: 'id = ?', whereArgs: [id]).then((_) {});

  /// Stores the deck the Agent is building. The slides stay in the app's
  /// private directory, so a deck survives the process being killed and can
  /// still be exported after a restart.
  Future<void> saveDeck(Deck deck, String session) => db
      .insert('decks', {
        'id': deck.id,
        'session': session,
        'record': jsonEncode(deck.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  /// The decks written in one conversation, oldest first, so the newest can
  /// become the active deck again after a restart.
  Future<List<Deck>> decks(String session) async =>
      (await db.query(
            'decks',
            where: 'session = ?',
            whereArgs: [session],
            orderBy: 'rowid ASC',
          ))
          .map(
            (row) => Deck.fromJson(
              jsonDecode(row['record'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();

  Future<void> deleteDeck(String id) =>
      db.delete('decks', where: 'id = ?', whereArgs: [id]).then((_) {});

  /// Removes one conversation's messages and the per-conversation settings that
  /// belong to it. The images it produced stay: they are the user's work, and
  /// the Gallery is where they are kept.
  Future<void> deleteSession(String session) async {
    await db.delete(
      'messages',
      where: 'session = ?',
      whereArgs: [session],
    );
    await db.delete(
      'settings',
      where: 'key = ?',
      whereArgs: ['conversation:$session'],
    );
  }

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

/// The pixel size the bytes actually carry, read from the file header alone.
///
/// What was asked for and what the service really produced are not always the
/// same — a request for 1536x1024 can come back square — so the size that gets
/// recorded and shown is the one measured here, with the requested one kept
/// beside it for comparison.
String? imageSizeOf(Uint8List bytes) =>
    _pngSize(bytes) ?? _jpegSize(bytes) ?? _webpSize(bytes);

String? _pngSize(Uint8List bytes) {
  // Signature, chunk length, "IHDR", then width and height as big-endian 32-bit
  // values.
  if (bytes.length < 24 || sniffMime(bytes) != 'image/png') return null;
  return '${_be32(bytes, 16)}x${_be32(bytes, 20)}';
}

String? _jpegSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var index = 2;
  while (index + 9 < bytes.length) {
    if (bytes[index] != 0xFF) {
      index++;
      continue;
    }
    // Any number of 0xFF bytes may precede a marker as fill; taking the second
    // one for the marker would read `C0 00` as a length and skip past the frame.
    var next = index + 1;
    while (next < bytes.length && bytes[next] == 0xFF) {
      next++;
    }
    // The fill run moves past what the loop's bound on `index` vouched for, and
    // the readings below reach up to `next + 7`: without this check a truncated
    // buffer throws RangeError instead of reporting no size.
    if (next + 8 >= bytes.length) return null;
    final marker = bytes[next];
    // A start-of-frame marker is the one that carries the dimensions; every
    // other segment is skipped by its own declared length.
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final height = (bytes[next + 4] << 8) | bytes[next + 5];
      final width = (bytes[next + 6] << 8) | bytes[next + 7];
      return '${width}x$height';
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      index = next + 1;
      continue;
    }
    final length = (bytes[next + 1] << 8) | bytes[next + 2];
    if (length < 2) return null;
    index = next + 1 + length;
  }
  return null;
}

String? _webpSize(Uint8List bytes) {
  if (bytes.length < 30 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WEBP') {
    return null;
  }
  final kind = String.fromCharCodes(bytes.sublist(12, 16));
  if (kind == 'VP8X') {
    final width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
    final height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
    return '${width}x$height';
  }
  if (kind == 'VP8 ') {
    final width = ((bytes[27] << 8) | bytes[26]) & 0x3FFF;
    final height = ((bytes[29] << 8) | bytes[28]) & 0x3FFF;
    return '${width}x$height';
  }
  if (kind == 'VP8L' && bytes.length >= 25) {
    final bits =
        bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    return '${(bits & 0x3FFF) + 1}x${((bits >> 14) & 0x3FFF) + 1}';
  }
  return null;
}

int _be32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

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
