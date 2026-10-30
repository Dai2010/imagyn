import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

import 'support/deck_studio.dart';

void main() {
  // Kept out of the widget suite: the test binding answers HTTP with 400, so a
  // turn that needs a real socket has to live in its own file.
  test('a turn adds up the usage of every request it made', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final subscription = server.listen((request) async {
      await request.drain<void>();
      final step = requests++;
      final message = step == 0
          ? {
              'content': '',
              'tool_calls': [
                {
                  'type': 'function',
                  'function': {
                    'name': 'create_deck',
                    'arguments': jsonEncode({
                      'title': '用量',
                      'aspect_ratio': '16:9',
                    }),
                  },
                },
              ],
            }
          : {'content': '做好了。'};
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {'message': message},
          ],
          'usage': step == 0
              ? {'prompt_tokens': 10, 'completion_tokens': 2}
              : {'prompt_tokens': 20, 'completion_tokens': 5},
        }),
      );
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

    await studio.submit('做一份演示文稿', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(requests, 2);
    expect(studio.turnUsage?.input, 30);
    expect(studio.turnUsage?.output, 7);
  });
}
