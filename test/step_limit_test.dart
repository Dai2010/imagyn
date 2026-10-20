import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

import 'support/deck_studio.dart';

Map<String, dynamic> toolCall(String name, Map<String, dynamic> arguments) => {
  'content': '',
  'tool_calls': [
    {
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(arguments)},
    },
  ],
};

void main() {
  test('the last step is a wrap-up without tools', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    Map<String, dynamic>? last;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests++;
      request.response.headers.contentType = ContentType.json;
      if (requests < 32) {
        request.response.write(
          jsonEncode({
            'choices': [
              {'message': toolCall('fetch_url', {'url': 'http://127.0.0.1/'})},
            ],
          }),
        );
      } else {
        last = body;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '已到上限：完成了检索，没有剩余步骤。'},
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    final store = DeckStore()
      ..savedConfig = ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'agent',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('一直查下去', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(requests, 32);
    // The wrap-up request carries no tool list, so the model cannot start a
    // call the loop would cut off without an answer.
    expect(last, isNotNull);
    expect(last!.containsKey('tools'), isFalse);
    final system = ((last!['messages'] as List).first as Map)['content'] as String;
    expect(system, contains('Turn budget reached'));
    expect(studio.chat.last.text, '已到上限：完成了检索，没有剩余步骤。');
    expect(
      studio.chat.where((entry) => entry.role == 'tool'),
      hasLength(31),
      reason: 'steps 1-31 each ran their tool before the wrap-up',
    );
  });
}
