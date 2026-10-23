import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

class _Store implements LocalStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('lists video models from the video service with the video key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/clip/models');
      expect(request.headers.value('authorization'), 'Bearer clip-key');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"data":[{"id":"my-relay-video-1"},{"id":"seedance-x"}]}');
      await request.response.close();
    });

    final client = StudioApi(
      ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        videoBaseUrl: 'http://127.0.0.1:${server.port}/clip',
      ),
      'main-key',
      'image-key',
      _Store(),
      videoKey: 'clip-key',
    );
    addTearDown(client.close);

    expect(await client.listVideoModels(), [
      'my-relay-video-1',
      'seedance-x',
    ]);
  });
}
