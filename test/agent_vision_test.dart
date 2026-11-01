import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';

/// A tool result carrying what the call produced, the way the turn loop stores
/// it.
ChatEntry result(String id, List<String> assets) => ChatEntry(
  'tool',
  'Generated 1 picture: ${assets.join(', ')}',
  callId: id,
  name: 'generate_image',
  assetIds: assets,
);

void main() {
  group('agentTurnImageIds', () {
    test('reads back to the user message and keeps the order they were made', () {
      final history = [
        const ChatEntry('user', 'three posters, same style'),
        const ChatEntry(
          'assistant',
          '',
          calls: [AgentCall('c1', 'generate_image', {})],
        ),
        result('c1', ['first']),
        const ChatEntry('assistant', '', assetIds: ['first']),
        const ChatEntry(
          'assistant',
          '',
          calls: [AgentCall('c2', 'generate_image', {})],
        ),
        result('c2', ['second', 'third']),
      ];
      // Newest first, because the caller walks back through the history.
      expect(agentTurnImageIds(history), ['third', 'second', 'first']);
    });

    test('stops at the user message, so an older turn stays out', () {
      final history = [
        const ChatEntry('user', 'make one'),
        result('c1', ['old']),
        const ChatEntry('user', 'now a different one'),
        result('c2', ['new']),
        const ChatEntry('assistant', '', assetIds: ['new']),
      ];
      expect(agentTurnImageIds(history), ['new']);
    });

    test('treats a picture the user attached as theirs, not as a product', () {
      final history = [
        const ChatEntry('user', '', assetIds: ['attached']),
        result('c1', ['made']),
        const ChatEntry('assistant', '', assetIds: ['made']),
      ];
      expect(agentTurnImageIds(history), ['made']);
    });

    test('takes the most recent pictures when a turn outgrows the budget', () {
      final history = [
        const ChatEntry('user', 'nine pictures'),
        result('c1', ['1', '2', '3', '4']),
        result('c2', ['5', '6', '7', '8', '9']),
      ];
      expect(agentTurnImageIds(history), ['9', '8', '7', '6']);
      expect(agentVisionMaxImages, 4);
    });

    test('does not read the same picture twice', () {
      final history = [
        const ChatEntry('user', 'one picture'),
        result('c1', ['same']),
        const ChatEntry('assistant', '', assetIds: ['same']),
      ];
      expect(agentTurnImageIds(history), ['same']);
    });

    test('returns nothing when the turn has produced no picture', () {
      expect(agentTurnImageIds([const ChatEntry('user', 'just talking')]), isEmpty);
    });
  });

  group('agentVisionMessage', () {
    const images = [(mime: 'image/jpeg', data: 'QUJD')];

    test('writes an OpenAI image_url part', () {
      final message = agentVisionMessage(ApiProtocol.openai, images)!;
      expect(message['role'], 'user');
      final content = message['content'] as List;
      expect(content.first, {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,QUJD'},
      });
      expect((content.last as Map)['type'], 'text');
    });

    test('writes an Anthropic image block with a base64 source', () {
      final content =
          agentVisionMessage(ApiProtocol.anthropic, images)!['content'] as List;
      expect(content.first, {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/jpeg',
          'data': 'QUJD',
        },
      });
      expect((content.last as Map)['type'], 'text');
    });

    test('writes a Responses input_image part', () {
      final content =
          agentVisionMessage(ApiProtocol.responses, images)!['content'] as List;
      expect(content.first, {
        'type': 'input_image',
        'image_url': 'data:image/jpeg;base64,QUJD',
      });
      expect((content.last as Map)['type'], 'input_text');
    });

    test('keeps the order the pictures were made in and counts them', () {
      final content =
          agentVisionMessage(ApiProtocol.openai, [
                (mime: 'image/png', data: 'QQ=='),
                (mime: 'image/png', data: 'Qg=='),
              ])!['content']
              as List;
      expect((content[0] as Map)['image_url'], {
        'url': 'data:image/png;base64,QQ==',
      });
      expect((content[1] as Map)['image_url'], {
        'url': 'data:image/png;base64,Qg==',
      });
      expect((content[2] as Map)['text'], contains('pictures'));
    });

    test('adds no message when there is nothing to show', () {
      expect(agentVisionMessage(ApiProtocol.openai, const []), isNull);
    });
  });
}
