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
  // Kept out of the widget suites: this one needs a real socket, and the test
  // binding answers every HTTP request with 400.
  test('a record that produced no picture can be listed and deleted', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final subscription = server.listen((request) async {
      await request.drain<void>();
      final message = switch (requests++) {
        // Deleting before listing is refused: the id was never seen.
        0 => toolCall('delete_image', {'image_id': 'job-1'}),
        1 => toolCall('list_images', {'limit': 10, 'query': ''}),
        2 => toolCall('delete_image', {'image_id': 'job-1'}),
        _ => {'content': '清掉了那条记录。'},
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
      )
      ..savedJobs['job-1'] = ImageJob('job-1', 'unknown', {
        'prompt': '红色狐狸',
        'createdAt': '2026-10-30T09:00:00.000',
        'kind': 'image',
      });
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('把那条没结果的记录清掉', true, const ImageOptions());

    expect(studio.error, isNull);
    final results = studio.chat
        .where((entry) => entry.role == 'tool')
        .map((entry) => entry.text)
        .toList();
    expect(results, hasLength(3));
    expect(results[0], contains('refused'));
    expect(results[1], contains('job-1'));
    expect(results[1], contains('result unknown'));
    expect(results[1], contains('红色狐狸'));
    expect(results[2], contains('Deleted the record job-1'));
    expect(store.savedJobs, isEmpty);
    expect(studio.jobs, isEmpty);
    expect(studio.chat.last.text, '清掉了那条记录。');
    expect(requests, 4);
  });
}
