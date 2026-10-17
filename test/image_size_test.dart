import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

Uint8List bytes(List<int> head, {int pad = 0}) {
  final data = Uint8List(head.length + pad);
  data.setRange(0, head.length, head);
  return data;
}

void main() {
  test('a PNG reports the size carried in its IHDR chunk', () {
    final png = bytes([
      137, 80, 78, 71, 13, 10, 26, 10, // signature
      0, 0, 0, 13, 73, 72, 68, 82, // chunk length + "IHDR"
      0, 0, 6, 0, // width 1536
      0, 0, 4, 0, // height 1024
      8, 6, 0, 0, 0,
    ]);
    expect(imageSizeOf(png), '1536x1024');
  });

  test('a JPEG reports the size from its start-of-frame marker', () {
    final jpeg = bytes([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x10, // APP0, declared length 16
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17, sample precision 8
      0x04, 0x00, // height 1024
      0x06, 0x00, // width 1536
      0x03, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1,
    ]);
    expect(imageSizeOf(jpeg), '1536x1024');
  });

  test('JPEG fill bytes before a marker are skipped', () {
    // A conforming encoder may pad a marker with 0xFF; reading the second one as
    // the marker would take `C0 00` for a length and lose the frame entirely.
    final jpeg = bytes([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x10, // APP0, declared length 16
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0xFF, 0xFF, 0xFF, 0xFF, 0xC0, 0x00, 0x11, 0x08, // fill, then SOF0
      0x04, 0x00, // height 1024
      0x06, 0x00, // width 1536
      0x03, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1,
    ]);
    expect(imageSizeOf(jpeg), '1536x1024');
  });

  test('a buffer that runs out inside the fill bytes reports nothing', () {
    // The loop's own bound still passed, but the fill run eats the rest of the
    // buffer: without a bounds check the frame fields would be read past the end
    // and this would throw RangeError instead of answering "no size".
    final truncated = bytes([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x10, // APP0, declared length 16
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC0, // fill, then nothing
    ]);
    expect(imageSizeOf(truncated), isNull);
  });

  test('a WebP reports the size from its VP8X chunk', () {
    final webp = bytes([
      ...'RIFF'.codeUnits, 0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...'VP8X'.codeUnits, 0, 0, 0, 0,
      0, 0, 0, 0, // flags and reserved
      0xFF, 0x05, 0x00, // width - 1 = 1535
      0xFF, 0x03, 0x00, // height - 1 = 1023
      0, 0, 0, 0, 0, 0,
    ]);
    expect(imageSizeOf(webp), '1536x1024');
  });

  test('bytes that are not a known image report nothing', () {
    expect(imageSizeOf(Uint8List(0)), isNull);
    expect(imageSizeOf(Uint8List.fromList([1, 2, 3, 4])), isNull);
    // A truncated header must not be read past its end.
    expect(
      imageSizeOf(
        Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]),
      ),
      isNull,
    );
  });

  test('every ratio maps to one pixel pair, and back', () {
    expect(sizePresets['16:9'], '1280x720');
    expect(sizePresets['21:9'], '1280x544');
    expect(ratioOfSize('1280x720'), '16:9');
    expect(ratioOfSize('1024x1024'), '1:1');
    expect(ratioOfSize('auto'), isNull);
    expect(ratioOfSize('999x999'), isNull);
    for (final entry in sizePresets.entries) {
      expect(
        RegExp(r'^[1-9]\d{1,4}x[1-9]\d{1,4}$').hasMatch(entry.value),
        isTrue,
        reason: '${entry.key} -> ${entry.value} must be a valid size',
      );
    }
  });
}
