import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

void main() {
  test('ask result splits the question from its options', () {
    final result = askResult(
      'Question for the user: 要横屏还是竖屏？ Options: 16:9 / 9:16. '
      'The turn ends here; the user\'s next message is the answer.',
    );
    expect(result.question, '要横屏还是竖屏？');
    expect(result.options, ['16:9', '9:16']);
  });

  test('a free-form ask has no options', () {
    final result = askResult(
      'Question for the user: 描述一下想要的画面。 '
      'The turn ends here; the user\'s next message is the answer.',
    );
    expect(result.question, '描述一下想要的画面。');
    expect(result.options, isEmpty);
  });
}
