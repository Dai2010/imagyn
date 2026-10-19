import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/tokens.dart';

void main() {
  test('wide characters cost a token, Latin a quarter', () {
    expect(estimateTokens(''), 0);
    expect(estimateTokens('abcd'), 1);
    expect(estimateTokens('中文'), 2);
    expect(estimateTokens('中文abcd'), 3);
  });

  test('history estimates include reasoning and tool arguments', () {
    const plain = ChatEntry('assistant', '');
    const withParts = ChatEntry(
      'assistant',
      '',
      reasoning: '想一下',
      calls: [
        AgentCall('call-1', 'generate_image', {'prompt': 'a fox'}),
      ],
    );
    expect(
      estimateHistoryTokens([withParts]),
      greaterThan(estimateHistoryTokens([plain])),
    );
    expect(estimateHistoryTokens([plain]), 4);
    expect(
      estimateHistoryTokens([const ChatEntry('user', 'abcd')]),
      5,
    );
  });
}
