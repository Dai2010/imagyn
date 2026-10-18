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

  test('a generated image is attached to the slide through "last"', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
    );
    var requests = 0;
    String? deckId;
    final subscription = server.listen((request) async {
      if (request.uri.path.endsWith('/images/generations')) {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(png)},
            ],
          }),
        );
        await request.response.close();
        return;
      }
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      for (final message in body['messages'] as List? ?? []) {
        final content = (message as Map)['content'];
        if (content is! String) continue;
        final match = RegExp(r'created with id (\S+) \(').firstMatch(content);
        if (match != null) deckId = match.group(1);
      }
      final message = switch (requests++) {
        0 => toolCall('create_deck', {
          'title': '图片演示',
          'aspect_ratio': '16:9',
        }),
        1 => toolCall('generate_image', {
          'prompt': '一只狐狸',
          'aspect_ratio': '16:9',
        }),
        2 => toolCall('add_slide', {
          'deck': deckId,
          'title': '狐狸',
          'bullets': ['要点'],
          'image_id': 'last',
        }),
        3 => toolCall('add_table', {
          'deck': deckId,
          'index': 0,
          'rows': [['属性', '值'], ['配图', '狐狸']],
          'header_row': true,
        }),
        4 => toolCall('update_slide', {
          'deck': deckId,
          'index': 0,
          'title': '狐狸与表格',
          'bullets': ['更新要点'],
        }),
        5 => toolCall('finish_deck', {'deck': deckId}),
        _ => {'content': '做好了。'},
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
        imageModel: 'image',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('做一份带图的演示文稿', true, const ImageOptions());

    expect(studio.error, isNull);
    final deck = studio.decks.values.single;
    expect(studio.gallery, hasLength(1));
    expect(deck.slides.single.imageId, studio.gallery.single.id);
    expect(deck.slides.single.table!.rows, [['属性', '值'], ['配图', '狐狸']]);
    expect(deck.slides.single.title, '狐狸与表格');
    expect(
      studio.chat.any(
        (entry) => entry.role == 'tool' && entry.text.contains('with image'),
      ),
      isTrue,
    );
  });

  test('an unknown image_id is answered instead of making a broken slide', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    String? deckId;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      for (final message in body['messages'] as List? ?? []) {
        final content = (message as Map)['content'];
        if (content is! String) continue;
        final match = RegExp(r'created with id (\S+) \(').firstMatch(content);
        if (match != null) deckId = match.group(1);
      }
      final message = switch (requests++) {
        0 => toolCall('create_deck', {
          'title': '测试',
          'aspect_ratio': '16:9',
        }),
        1 => toolCall('add_slide', {
          'deck': deckId,
          'title': '无图',
          'bullets': ['要点'],
          'image_id': 'no-such-image',
        }),
        _ => {'content': '我再试一次。'},
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

    await studio.submit('做一份演示文稿', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(studio.decks.values.single.slides, isEmpty);
    expect(
      studio.chat.any(
        (entry) => entry.role == 'tool' && entry.text.contains('Unknown image_id'),
      ),
      isTrue,
    );
  });

  test('a failed tool leaves a result for every call in the turn', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var chatRequests = 0;
    final subscription = server.listen((request) async {
      if (request.uri.path.endsWith('/images/generations')) {
        await request.drain<void>();
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":{"message":"upstream"}}');
        await request.response.close();
        return;
      }
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': chatRequests++ == 0
                  ? {
                      'content': '',
                      'tool_calls': [
                        {
                          'id': 'c1',
                          'type': 'function',
                          'function': {
                            'name': 'generate_image',
                            'arguments': jsonEncode({
                              'prompt': 'a',
                              'aspect_ratio': 'auto',
                            }),
                          },
                        },
                        {
                          'id': 'c2',
                          'type': 'function',
                          'function': {
                            'name': 'generate_image',
                            'arguments': jsonEncode({
                              'prompt': 'b',
                              'aspect_ratio': 'auto',
                            }),
                          },
                        },
                      ],
                    }
                  : {'content': 'ok'},
            },
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
        imageModel: 'image',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('draw two pictures', true, const ImageOptions());

    expect(studio.error, isNotNull);
    final tools = studio.chat.where((entry) => entry.role == 'tool').toList();
    expect(tools, hasLength(2));
    expect(tools.map((entry) => entry.callId), ['c1', 'c2']);
    expect(tools.first.text, startsWith('Tool failed:'));
    expect(tools.last.text, contains('Not run'));
  });
}
