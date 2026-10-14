import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/store.dart';

void main() {
  group('sniffMime', () {
    test('recognises PNG', () {
      expect(sniffMime(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
          'image/png');
    });

    test('recognises JPEG', () {
      expect(sniffMime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
    });

    test('recognises WebP', () {
      final bytes = Uint8List.fromList([
        ...'RIFF'.codeUnits, 0x20, 0x00, 0x00, 0x00, ...'WEBP'.codeUnits,
      ]);
      expect(sniffMime(bytes), 'image/webp');
    });

    test('rejects a body that is not a supported image', () {
      expect(
        () => sniffMime(Uint8List.fromList([0x00, 0x01, 0x02])),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', 'invalidImage')),
      );
      expect(
        () => sniffMime(Uint8List.fromList('RIFF-not-webp!'.codeUnits)),
        throwsA(isA<FormatException>()),
      );
      expect(() => sniffMime(Uint8List(0)), throwsA(isA<FormatException>()));
    });
  });
}
