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

  test('on DeepSeek the service fetches the page and returns markdown',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    Map<String, dynamic>? fetchBody;
    final subscription = server.listen((request) async {
      if (request.uri.path.endsWith('/tools/fetch')) {
        fetchBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'title': '页面标题', 'content': '# 正文\n\n一段话'}),
        );
        await request.response.close();
        return;
      }
      await utf8.decoder.bind(request).join();
      final message = switch (calls++) {
        0 => toolCall('fetch_url', {
          'url': 'https://example.com/post',
          'format': 'markdown',
        }),
        _ => {'content': '读完了。'},
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
        agentModel: 'deepseek-flash',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('读一下这个页面', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(fetchBody?['url'], 'https://example.com/post');
    final result = studio.chat.singleWhere((entry) => entry.role == 'tool');
    expect(result.text, contains('TITLE: 页面标题'));
    expect(result.text, contains('fetched by the service'));
    expect(result.text, contains('# 正文'));
    expect(studio.chat.last.text, '读完了。');
  });

  test('a refused server-side fetch falls back to the local one', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    final subscription = server.listen((request) async {
      if (request.uri.path.endsWith('/tools/fetch')) {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }
      await utf8.decoder.bind(request).join();
      final message = switch (calls++) {
        0 => toolCall('fetch_url', {
          'url': 'http://127.0.0.1/secret',
          'format': 'markdown',
        }),
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
        agentModel: 'deepseek-flash',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('看看这个页面', true, const ImageOptions());

    expect(studio.error, isNull);
    final result = studio.chat.singleWhere((entry) => entry.role == 'tool');
    // The service could not fetch it, so the local rules answered instead:
    // loopback is still refused rather than reaching the network.
    expect(result.text, contains('fetch_url refused'));
    expect(result.text, isNot(contains('fetched by the service')));
  });
}
