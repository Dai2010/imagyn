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
        5 => toolCall('set_background', {
          'deck': deckId,
          'image_id': 'last',
          'index': -1,
          'color': '',
        }),
        6 => toolCall('finish_deck', {'deck': deckId}),
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
    expect(deck.backgroundImageId, studio.gallery.single.id);
    expect(deck.backgroundFor(deck.slides.single), studio.gallery.single.id);
    expect(
      studio.chat.any(
        (entry) => entry.role == 'tool' && entry.text.contains('with image'),
      ),
      isTrue,
    );
  });

  test('free elements are added, survive other tools and can be removed', () async {
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
          'title': '自由排版',
          'aspect_ratio': '16:9',
        }),
        1 => toolCall('generate_image', {
          'prompt': '一张照片',
          'aspect_ratio': '1:1',
        }),
        2 => toolCall('add_slide', {
          'deck': deckId,
          'title': '',
          'bullets': <String>[],
          'image_id': '',
        }),
        // A box hanging off the page must be answered, not written.
        3 => toolCall('add_text', {
          'deck': deckId,
          'index': 0,
          'text': '越界',
          'x': 0.9,
          'y': 0.1,
          'width': 0.5,
          'height': 0.2,
          'font_size': 32,
          'color': '1F1B2E',
          'bold': false,
          'italic': false,
          'align': 'left',
          'font': '',
          'padding': 0,
          'line_spacing': 1.15,
          'fill': '',
          'border': '',
          'radius': 0,
        }),
        4 => toolCall('add_text', {
          'deck': deckId,
          'index': 0,
          'text': '封面标题',
          'x': 0.06,
          'y': 0.1,
          'width': 0.6,
          'height': 0.2,
          'font_size': 44,
          'color': 'FFFFFF',
          'bold': true,
          'italic': false,
          'align': 'center',
          'font': '',
          'padding': 0,
          'line_spacing': 1.15,
          'fill': '1F1B2E',
          'border': '7863C7',
          'radius': 0.15,
        }),
        5 => toolCall('add_image', {
          'deck': deckId,
          'index': 0,
          'image_id': 'last',
          'x': 0.06,
          'y': 0.45,
          'width': 0.4,
          'height': 0.45,
          'fit': 'cover',
          'radius': 0.1,
          'border': '',
        }),
        // update_slide replaces the standard slots only; the elements stay.
        6 => toolCall('update_slide', {
          'deck': deckId,
          'index': 0,
          'title': '新标题',
          'bullets': ['保留元素'],
        }),
        7 => toolCall('remove_element', {
          'deck': deckId,
          'index': 0,
          'element': 'e1',
        }),
        8 => toolCall('finish_deck', {'deck': deckId}),
        _ => {'content': '好了。'},
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

    await studio.submit('做一张海报式封面', true, const ImageOptions());

    expect(studio.error, isNull);
    final deck = studio.decks.values.single;
    final slide = deck.slides.single;
    expect(slide.title, '新标题');
    expect(slide.elements, hasLength(1));
    final element = slide.elements.single;
    expect(element.id, 'e2');
    expect(element.kind, SlideElementKind.image);
    expect(element.imageId, studio.gallery.single.id);
    expect(element.fit, 'cover');
    expect(element.radius, .1);

    final results = [
      for (final entry in studio.chat)
        if (entry.role == 'tool') entry.text,
    ];
    expect(
      results.any((text) => text.contains('Invalid arguments for add_text')),
      isTrue,
    );
    expect(results.any((text) => text.contains('Text element e1')), isTrue);
    expect(results.any((text) => text.contains('Image element e2')), isTrue);
    expect(results.any((text) => text.contains('Element e1 removed')), isTrue);
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

    expect(studio.error, isNull);
    expect(studio.chat.last.text, 'ok');
    final tools = studio.chat.where((entry) => entry.role == 'tool').toList();
    expect(tools, hasLength(2));
    expect(tools.map((entry) => entry.callId), ['c1', 'c2']);
    expect(
      tools.every((entry) => entry.text.startsWith('Image generation failed')),
      isTrue,
    );
  });

  test('ask_user ends the turn and the reply becomes the next answer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final bodies = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      bodies.add(body);
      final message = switch (requests++) {
        0 => toolCall('ask_user', {
          'question': '幻灯片要多宽？',
          'options': ['16:9', '4:3'],
        }),
        _ => {'content': '好，按 16:9。'},
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
    expect(requests, 1);
    final question = studio.chat.singleWhere((entry) => entry.role == 'tool');
    expect(question.name, 'ask_user');
    expect(question.text, contains('幻灯片要多宽？'));

    await studio.submit('16:9', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(requests, 2);
    final messages = bodies.last['messages'] as List;
    expect(
      messages.any(
        (entry) =>
            (entry as Map)['role'] == 'tool' &&
            (entry['content'] as String).contains('Question for the user'),
      ),
      isTrue,
    );
    expect(messages.last, {'role': 'user', 'content': '16:9'});
    expect(studio.chat.last.text, '好，按 16:9。');
  });

  test('a deck is stored in the app directory and survives a restart', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      String? deckId;
      for (final message in body['messages'] as List? ?? []) {
        final content = (message as Map)['content'];
        if (content is! String) continue;
        final match = RegExp(r'created with id (\S+) \(').firstMatch(content);
        if (match != null) deckId = match.group(1);
      }
      final message = switch (requests++) {
        0 => toolCall('create_deck', {
          'title': '持久演示',
          'aspect_ratio': '16:9',
        }),
        1 => toolCall('add_slide', {
          'deck': deckId,
          'title': '第一页',
          'bullets': ['要点'],
          'image_id': '',
        }),
        2 => toolCall('finish_deck', {'deck': deckId}),
        _ => {'content': '好了。'},
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
    await studio.initialize();
    await studio.submit('做一份演示文稿', true, const ImageOptions());
    expect(studio.error, isNull);
    final session = studio.session;
    final id = studio.decks.values.single.id;
    studio.dispose();

    final restored = DeckStudio(store);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.session, session);
    expect(restored.decks.keys, [id]);
    final deck = restored.decks[id]!;
    expect(deck.title, '持久演示');
    expect(deck.finished, isTrue);
    expect(deck.slides.single.title, '第一页');
    expect(restored.activeDeck, same(deck));
  });
}
