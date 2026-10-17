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
  // A separate file from the workspace widget tests: TestWidgetsFlutterBinding
  // answers every HTTP request with 400, so a test that needs a real socket
  // has to stay out of a suite that has widget tests in it.
  test('one turn can create, fill and finish a deck', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      // add_slide and finish_deck name the deck by the id create_deck returned.
      String? deckId;
      for (final message in body['messages'] as List? ?? []) {
        final content = (message as Map)['content'];
        if (content is! String) continue;
        final match = RegExp(r'created with id (\S+) \(').firstMatch(content);
        if (match != null) deckId = match.group(1);
      }
      final message = switch (requests++) {
        0 => toolCall('create_deck', {
          'title': '测试演示',
          'aspect_ratio': '16:9',
        }),
        1 => toolCall('add_slide', {
          'deck': deckId,
          'title': '第一页',
          'bullets': ['要点'],
          'image_id': '',
        }),
        2 => toolCall('finish_deck', {'deck': deckId}),
        _ => {'content': '演示文稿做好了。'},
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

    await studio.submit('做一个演示文稿', true, const ImageOptions());

    expect(studio.error, isNull);
    final deck = studio.decks.values.single;
    expect(studio.activeDeck, same(deck));
    expect(deck.title, '测试演示');
    expect(deck.slides.single.title, '第一页');
    expect(deck.finished, isTrue);
    expect(studio.runningTool, isNull);
    expect(studio.chat.last.text, '演示文稿做好了。');
    expect(requests, 4);
  });
}
