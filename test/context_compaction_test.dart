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

  test('the manual command compacts even with the automatic limit off', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      bodies.add(body);
      final messages = body['messages'] as List;
      final system = (messages.first as Map)['content'] as String? ?? '';
      request.response.headers.contentType = ContentType.json;
      if (system.contains('condense a long conversation')) {
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'MANUAL-SUMMARY'},
              },
            ],
          }),
        );
      } else {
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
    // No contextTokens: this is the manual path, not the automatic one.
    await store.addMessage(studio.session, const ChatEntry('user', 'early-1'));
    await store.addMessage(
      studio.session,
      const ChatEntry('assistant', 'reply-1'),
    );
    await store.addMessage(studio.session, const ChatEntry('user', 'early-2'));
    await store.addMessage(
      studio.session,
      const ChatEntry('assistant', 'reply-2'),
    );
    await store.addMessage(studio.session, const ChatEntry('user', 'latest'));
    await studio.refresh();

    final result = await studio.compactNow();

    expect(result.compacted, 4);
    expect(result.kept, 1);
    expect(studio.busy, isFalse);
    expect(studio.error, isNull);
    expect(bodies, hasLength(1));
    final transcript = (bodies.single['messages'].last as Map)['content'];
    expect(transcript, contains('early-1'));
    expect(transcript, contains('reply-2'));
    expect(
      transcript,
      isNot(contains('latest')),
      reason: 'the newest turn is kept verbatim, not summarized',
    );

    await studio.submit('continue', true, const ImageOptions());

    expect(studio.error, isNull);
    expect(bodies, hasLength(2));
    final sent = bodies.last['messages'] as List;
    expect(
      (sent.first as Map)['content'],
      contains('MANUAL-SUMMARY'),
      reason: 'the manual checkpoint rides in the system prompt',
    );
    expect(
      sent.any(
        (entry) =>
            ((entry as Map)['content'] as String? ?? '').contains('early-1'),
      ),
      isFalse,
      reason: 'the folded turns are not sent again',
    );
    expect(
      sent.any(
        (entry) =>
            ((entry as Map)['content'] as String? ?? '').contains('latest'),
      ),
      isTrue,
    );
  });

  test('the manual command reports an empty conversation', () async {
    final studio = DeckStudio(MemoryStore());
    addTearDown(studio.dispose);
    await studio.initialize();

    await expectLater(
      studio.compactNow(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'compactEmpty',
        ),
      ),
    );
    expect(studio.busy, isFalse);
  });
}
