import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/video.dart';

void main() {
  group('firstFrameId', () {
    test('keeps the checked picture when the call names no frame', () {
      expect(firstFrameId('', ['newer', 'older'], 'checked'), 'checked');
    });

    test('takes the newest picture for "last" and "latest"', () {
      expect(firstFrameId('last', ['newer', 'older'], 'checked'), 'newer');
      expect(firstFrameId('latest', ['only'], ''), 'only');
    });

    test('falls back to the checked picture when nothing exists yet', () {
      expect(firstFrameId('last', const [], 'checked'), 'checked');
    });

    test('accepts a picture this conversation produced', () {
      expect(firstFrameId('shot-3', ['shot-3', 'shot-2'], 'checked'), 'shot-3');
    });

    test('answers empty for an id it never produced, so the call can be '
        'corrected instead of posting a request the service rejects', () {
      expect(firstFrameId('made-up', ['shot-3'], 'checked'), '');
    });

    test('ignores surrounding spaces in the argument', () {
      expect(firstFrameId('  shot-3  ', ['shot-3'], ''), 'shot-3');
    });
  });
}
