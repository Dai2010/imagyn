import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:imagyn/core/vision_cache.dart';

/// A solid PNG of the given size, standing in for a generated picture.
Uint8List picture(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(40, 60, 120));
  return img.encodePng(image);
}

void main() {
  late Directory directory;
  late VisionCache cache;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('imagyn-vision-');
    cache = VisionCache(directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('writes a copy with the longest side at most maxSide', () async {
    final payload = await cache.get('wide', () async => picture(1600, 1200));
    expect(payload, isNotNull);
    expect(payload!.mime, 'image/jpeg');
    final written = img.decodeImage(base64Decode(payload.data))!;
    expect(written.width, VisionCache.maxSide);
    expect(written.height, lessThanOrEqualTo(VisionCache.maxSide));
  });

  test('leaves a picture that is already small at its own size', () async {
    final payload = await cache.get('small', () async => picture(320, 240));
    final written = img.decodeImage(base64Decode(payload!.data))!;
    expect(written.width, 320);
    expect(written.height, 240);
  });

  test('reads the copy back instead of decoding the source again', () async {
    var reads = 0;
    await cache.get('once', () async {
      reads++;
      return picture(1200, 800);
    });
    final again = await cache.get('once', () async {
      reads++;
      return picture(1200, 800);
    });
    expect(reads, 1);
    expect(again!.mime, 'image/jpeg');
  });

  test('keeps only the newest maxFiles copies', () async {
    for (var i = 0; i < VisionCache.maxFiles + 3; i++) {
      await cache.get('shot-$i', () async => picture(900, 600));
      // Distinct timestamps, so the rotation has a definite order to sort by:
      // a burst of writes can otherwise land in the same millisecond.
      await File(
        '${directory.path}/shot-$i.jpg',
      ).setLastModified(DateTime.utc(2026, 1, 1).add(Duration(minutes: i)));
    }
    final files = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.jpg'))
        .toList();
    expect(files.length, VisionCache.maxFiles);
    expect(
      files.any((file) => file.path.endsWith('shot-0.jpg')),
      isFalse,
      reason: 'the oldest copy should have been dropped',
    );
    expect(
      files.any(
        (file) => file.path.endsWith('shot-${VisionCache.maxFiles + 2}.jpg'),
      ),
      isTrue,
    );
  });

  test('answers null for bytes it cannot decode', () async {
    final payload = await cache.get(
      'broken',
      () async => Uint8List.fromList([1, 2, 3, 4]),
    );
    expect(payload, isNull);
  });
}
