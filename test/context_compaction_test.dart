import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

import 'support/deck_studio.dart';
import 'support/memory_store.dart';

void main() {
  // A separate file: TestWidgetsFlutterBinding answers every HTTP request with
  // 400, so a test that needs a real socket cannot share a suite with widgets.
  test('a long history is summarized before the window overflows', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      bodies.add(body);
      final messages = body['messages'] as List;
      final system =
          (messages.first as Map)['content'] as String? ?? '';
      request.response.headers.contentType = ContentType.json;
      if (system.contains('condense a long conversation')) {
        expect(
          (messages.last as Map)['content'],
          contains('early-0'),
          reason: 'everything outside the kept window is summarized',
        );
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'SUMMARY-TEXT'},
              },
            ],
          }),
        );
      } else {
        expect(system, contains('SUMMARY-TEXT'));
        expect(
          messages.any(
            (entry) =>
                ((entry as Map)['content'] as String? ?? '').contains(
                  'early-0',
                ),
          ),
          isFalse,
          reason: 'the summarized turns are not sent again',
        );
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'done'},
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    addTearDown(subscription.cancel);

    final store = MemoryStore()
      ..savedConfig = ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'agent',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    await studio.setAgentOptions(const AgentOptions(contextTokens: 12000));
    final padding = 'x' * 1000;
    for (var i = 0; i < 24; i++) {
      await store.addMessage(
        studio.session,
        ChatEntry('user', 'early-$i $padding'),
      );
      await store.addMessage(
        studio.session,
        ChatEntry('assistant', 'reply-$i $padding'),
      );
    }
    await studio.refresh();

    await studio.submit('latest', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(bodies, hasLength(2), reason: 'one summary request, one real turn');
    expect(studio.chat.last.text, 'done');
  });
}
