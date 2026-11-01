import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Small copies of the pictures a turn produced, handed to the text model so it
/// can look at what it made before deciding the next step.
///
/// Kept on disk rather than in memory: decoding one 1024px PNG costs megabytes,
/// and a turn that reviews four of them would spike far enough to get the app
/// killed on a phone with little RAM. A copy is made once per picture and read
/// back from the file afterwards; the directory lives under the app's own
/// folder, so no other app can read it and no gallery entry is created for it.
class VisionCache {
  VisionCache(this.directory);

  final Directory directory;

  /// Longest side of a copy. Enough to read a layout or spot a broken face,
  /// small enough to keep the request in the hundreds of kilobytes.
  static const maxSide = 768;

  /// How many copies are kept. Generous compared with the four a single request
  /// carries, so a short retry does not have to decode anything again.
  static const maxFiles = 24;

  static const _quality = 82;

  /// The copy of [id], made from [source] on first use.
  ///
  /// Returns null when the picture cannot be decoded: the picture is then left
  /// out of the request rather than failing it, since the tool result still
  /// says what was produced.
  Future<({String mime, String data})?> get(
    String id,
    Future<Uint8List> Function() source,
  ) async {
    final cached = File(p.join(directory.path, '$id.jpg'));
    try {
      if (await cached.exists() && await cached.length() > 0) {
        return (
          mime: 'image/jpeg',
          data: base64Encode(await cached.readAsBytes()),
        );
      }
    } catch (_) {}
    Uint8List? jpeg;
    try {
      final bytes = await source();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final longest = math.max(decoded.width, decoded.height);
      final small = longest <= maxSide
          ? decoded
          : img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? maxSide : null,
              height: decoded.height > decoded.width ? maxSide : null,
              interpolation: img.Interpolation.average,
            );
      jpeg = img.encodeJpg(small, quality: _quality);
    } catch (_) {
      return null;
    }
    try {
      await directory.create(recursive: true);
      await cached.writeAsBytes(jpeg);
      await _rotate();
    } catch (_) {
      // A read-only or full disk still gets this request its picture; only the
      // reuse is lost.
    }
    return (mime: 'image/jpeg', data: base64Encode(jpeg));
  }

  /// Drops the oldest copies beyond [maxFiles].
  Future<void> _rotate() async {
    final entries = <({File file, DateTime at})>[];
    await for (final entry in directory.list()) {
      if (entry is! File || !entry.path.endsWith('.jpg')) continue;
      try {
        entries.add((file: entry, at: (await entry.stat()).modified));
      } catch (_) {}
    }
    if (entries.length <= maxFiles) return;
    entries.sort((a, b) => a.at.compareTo(b.at));
    for (final entry in entries.take(entries.length - maxFiles)) {
      try {
        await entry.file.delete();
      } catch (_) {}
    }
  }
}
