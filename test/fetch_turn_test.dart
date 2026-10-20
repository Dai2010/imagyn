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
  test('fetch_url is offered and a private address is answered', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    List<dynamic>? tools;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      tools ??= body['tools'] as List?;
      final message = switch (requests++) {
        // Loopback is refused before any connection is made, so this test
        // never depends on the network.
        0 => toolCall('fetch_url', {'url': 'http://127.0.0.1/secret'}),
        _ => {'content': '打不开这个地址。'},
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {'message': message},
          ],
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

    await studio.submit('看看这个页面', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(
      tools!.any((tool) => (tool as Map)['function']['name'] == 'fetch_url'),
      isTrue,
    );
    final result = studio.chat.singleWhere((entry) => entry.role == 'tool');
    expect(result.name, 'fetch_url');
    expect(result.text, contains('fetch_url refused'));
    expect(studio.chat.last.text, '打不开这个地址。');
  });
}
