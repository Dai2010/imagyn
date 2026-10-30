import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

import 'support/deck_studio.dart';

Map<String, dynamic> toolCall(
  String id,
  String name,
  Map<String, dynamic> arguments,
) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(arguments)},
};

Future<HttpServer> serve(
  void Function(int step, Map<String, dynamic> body, HttpRequest request)
  answer,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var step = 0;
  server.listen((request) async {
    final text = await utf8.decoder.bind(request).join();
    answer(step++, jsonDecode(text) as Map<String, dynamic>, request);
  });
  return server;
}

Future<DeckStudio> open(HttpServer server) async {
  final store = DeckStore()
    ..savedConfig = ServiceConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      agentModel: 'agent',
      streamAgent: false,
    );
  final studio = DeckStudio(store);
  await studio.initialize();
  return studio;
}

void reply(HttpRequest request, Map<String, dynamic> message) {
  request.response.headers.contentType = ContentType.json;
  request.response.write(
    jsonEncode({
      'choices': [
        {'message': message},
      ],
    }),
  );
  request.response.close();
}

void main() {
  test('an interjection waits until every call has a result', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await serve((step, body, request) {
      bodies.add(body);
      if (step == 0) {
        reply(request, {
          'content': '',
          'tool_calls': [
            toolCall('c1', 'create_deck', {
              'title': '第一份',
              'aspect_ratio': '16:9',
            }),
            toolCall('c2', 'create_deck', {
              'title': '第二份',
              'aspect_ratio': '4:3',
            }),
          ],
        });
      } else {
        reply(request, {'content': '两份都做好了。'});
      }
    });
    addTearDown(() => server.close(force: true));
    final studio = await open(server);
    addTearDown(studio.dispose);

    final turn = studio.submit('做两份演示文稿', true, const ImageOptions());
    expect(
      studio.interject('/compact'),
      isFalse,
      reason: 'a slash command needs an idle app',
    );
    expect(studio.interject('标题改成英文'), isTrue);
    await turn;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(studio.queuedCount, 0);
    expect(bodies, hasLength(greaterThanOrEqualTo(2)));
    final sent = (bodies[1]['messages'] as List).cast<Map>();
    final lastTool = sent.lastIndexWhere((message) => message['role'] == 'tool');
    final interjection = sent.indexWhere(
      (message) =>
          message['role'] == 'user' &&
          '${message['content']}'.contains('标题改成英文'),
    );
    expect(lastTool, greaterThanOrEqualTo(0));
    expect(interjection, greaterThan(lastTool));
  });

  test('a question hands the queued text back instead of answering it', () async {
    final server = await serve((step, body, request) {
      if (step == 0) {
        reply(request, {
          'content': '',
          'tool_calls': [
            toolCall('c1', 'ask_user', {
              'question': '继续吗？',
              'options': ['是', '否'],
            }),
          ],
        });
      } else {
        reply(request, {'content': '好。'});
      }
    });
    addTearDown(() => server.close(force: true));
    final studio = await open(server);
    addTearDown(studio.dispose);

    final turn = studio.submit('做个决定', true, const ImageOptions());
    expect(studio.interject('这条是补充，不是答案'), isTrue);
    await turn;

    expect(studio.error, isNull);
    expect(studio.queuedCount, 0);
    expect(studio.takeDraft(), '这条是补充，不是答案');
  });

  test('a normal end starts the queued message as the next turn', () async {
    final bodies = <Map<String, dynamic>>[];
    final second = Completer<void>();
    final server = await serve((step, body, request) {
      if (step == 0) {
        reply(request, {'content': '第一轮完成。'});
      } else {
        bodies.add(body);
        reply(request, {'content': '第二轮完成。'});
        if (!second.isCompleted) second.complete();
      }
    });
    addTearDown(() => server.close(force: true));
    final studio = await open(server);
    addTearDown(studio.dispose);

    final turn = studio.submit('第一句', true, const ImageOptions());
    expect(studio.interject('第二句'), isTrue);
    await turn;

    await second.future.timeout(const Duration(seconds: 5));
    for (var i = 0; i < 100 && studio.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(studio.busy, isFalse);
    final sent = (bodies.single['messages'] as List).cast<Map>();
    expect(
      sent.any(
        (message) =>
            message['role'] == 'user' && message['content'] == '第二句',
      ),
      isTrue,
    );
  });
}
