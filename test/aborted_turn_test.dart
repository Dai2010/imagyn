import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

void main() {
  test('an aborted entry survives JSON and finished ones stay unflagged', () {
    const stopped = ChatEntry('assistant', '半句话', aborted: true);
    final restored = ChatEntry.fromJson(
      Map<String, dynamic>.from(stopped.toJson()),
    );
    expect(restored.aborted, isTrue);
    expect(restored.text, '半句话');

    const finished = ChatEntry('assistant', '完整回答');
    expect(finished.aborted, isFalse);
    expect(
      finished.toJson().containsKey('aborted'),
      isFalse,
      reason: 'only stopped turns carry the flag',
    );
    expect(
      ChatEntry.fromJson(Map<String, dynamic>.from(finished.toJson())).aborted,
      isFalse,
    );
  });
}
