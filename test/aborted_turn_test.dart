import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

import 'support/deck_studio.dart';

void main() {
  test('stopping a streaming turn keeps its text and marks it aborted', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final subscription = server.listen((request) async {
      await request.drain<void>();
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/event-stream',
      );
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '半句话'},
            },
          ],
        })}\n\n',
      );
      await request.response.flush();
      // Deliberately no close: the client is supposed to stop this stream.
    });
    addTearDown(subscription.cancel);
    final store = DeckStore()
      ..savedConfig = ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'agent',
        streamAgent: true,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    final turn = studio.submit('写一半', true, const ImageOptions());
    for (var i = 0; i < 100 && studio.streamingText.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(studio.streamingText, '半句话');
    studio.cancel();
    await turn;

    expect(studio.error, 'cancelled');
    final last = studio.chat.last;
    expect(last.role, 'assistant');
    expect(last.text, '半句话');
    expect(
      last.aborted,
      isTrue,
      reason: 'the UI has to say this was stopped, not finished',
    );
  });
}
