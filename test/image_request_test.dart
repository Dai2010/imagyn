import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

class TestStore implements LocalStore {
  TestStore(this.root);
  @override
  final Directory root;
  @override
  File file(Asset asset) => File('${root.path}/${asset.path}');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late HttpServer server;
  late Directory root;
  late StudioApi client;
  late StreamSubscription<HttpRequest> subscription;
  late Future<void> Function(HttpRequest) handler;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('imagyn-api-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((request) async {
      await handler(request);
    });
    client = StudioApi(
      ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        imageModel: 'gpt-image-2.5-flare',
      ),
      'test-agent-key',
      'test-image-key',
      TestStore(root),
    );
  });
  tearDown(() async {
    client.close();
    await subscription.cancel();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'sends the Playground JSON parameters and saves returned Base64 bytes',
    () async {
      handler = (request) async {
        expect(request.uri.path, '/v1/images/generations');
        expect(request.headers.value('authorization'), 'Bearer test-image-key');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body, {
          'model': 'gpt-image-2.5-flare',
          'prompt': 'an app icon',
          'size': 'auto',
          'quality': 'auto',
          'output_format': 'png',
          'moderation': 'auto',
          'background': 'transparent',
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(png)},
            ],
          }),
        );
        await request.response.close();
      };
      expect(
        await client.generate(
          'an app icon',
          [],
          const ImageOptions(transparent: true),
          CancelToken(),
        ),
        [png],
      );
    },
  );

  test('edits send repeated image[] parts and all selected fields', () async {
    await File('${root.path}/a.png').writeAsBytes(png);
    handler = (request) async {
      expect(request.uri.path, '/v1/images/edits');
      expect(request.headers.contentType?.mimeType, 'multipart/form-data');
      final body = latin1.decode(
        await request.fold<List<int>>([], (a, b) => a..addAll(b)),
      );
      expect(RegExp('name="image\\[\\]"').allMatches(body).length, 2);
      expect(body, contains('name="quality"\r\n\r\nhigh'));
      expect(body, contains('name="output_format"\r\n\r\nwebp'));
      expect(body, contains('name="n"\r\n\r\n2'));
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(png)},
          ],
        }),
      );
      await request.response.close();
    };
    final asset = Asset(
      id: 'a',
      path: 'a.png',
      mime: 'image/png',
      prompt: '',
      createdAt: DateTime(2026),
    );
    expect(
      await client.generate(
        'edit',
        [asset, asset],
        const ImageOptions(quality: 'high', format: 'webp', count: 2),
        CancelToken(),
      ),
      [png],
    );
  });

  test('URL downloads never carry the API credential', () async {
    handler = (request) async {
      if (request.uri.path == '/v1/images/generations') {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'http://127.0.0.1:${server.port}/image'},
            ],
          }),
        );
      } else {
        expect(request.headers.value('authorization'), isNull);
        request.response.add(png);
      }
      await request.response.close();
    };
    expect(
      await client.generate('icon', [], const ImageOptions(), CancelToken()),
      [png],
    );
  });

  test(
    'a failed image download retains its URL for download-only retry',
    () async {
      final url = 'http://127.0.0.1:${server.port}/image';
      handler = (request) async {
        if (request.uri.path == '/v1/images/generations') {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'url': url},
              ],
            }),
          );
        } else {
          request.response.statusCode = 503;
        }
        await request.response.close();
      };
      await expectLater(
        client.generate('icon', [], const ImageOptions(), CancelToken()),
        throwsA(
          isA<ImageApiException>()
              .having((e) => e.code, 'code', 'downloadFailed')
              .having((e) => e.outputs, 'outputs', [url]),
        ),
      );
    },
  );

  for (final base64First in [true, false]) {
    test(
      'mixed results support download-only retry, base64First=$base64First',
      () async {
        final url = 'http://127.0.0.1:${server.port}/image';
        final inline = 'data:image/*;base64,${base64Encode(png)}';
        final outputs = base64First ? [inline, url] : [url, inline];
        var generationRequests = 0;
        var downloadRequests = 0;
        var failDownload = true;
        handler = (request) async {
          if (request.uri.path == '/v1/images/generations') {
            generationRequests++;
            await request.drain<void>();
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'data': outputs
                    .map(
                      (output) => output == url
                          ? {'url': url}
                          : {'b64_json': base64Encode(png)},
                    )
                    .toList(),
              }),
            );
          } else {
            downloadRequests++;
            expect(request.headers.value('authorization'), isNull);
            if (failDownload) {
              request.response.statusCode = 503;
            } else {
              request.response.add(png);
            }
          }
          await request.response.close();
        };

        List<String>? recovered;
        try {
          await client.generate(
            'icon',
            [],
            const ImageOptions(count: 2),
            CancelToken(),
          );
          fail('Expected the download to fail');
        } on ImageApiException catch (error) {
          expect(error.code, 'downloadFailed');
          recovered = error.outputs;
        }
        expect(recovered, outputs);
        failDownload = false;
        expect(await client.downloadImages(recovered, CancelToken()), [
          png,
          png,
        ]);
        expect(generationRequests, 1);
        expect(downloadRequests, 2);
      },
    );
  }

  test('an invalid downloaded image retains its output for retry', () async {
    final url = 'http://127.0.0.1:${server.port}/image';
    var valid = false;
    handler = (request) async {
      request.response.add(
        valid ? png : utf8.encode('<html>temporarily unavailable</html>'),
      );
      await request.response.close();
    };
    await expectLater(
      client.downloadImages([url], CancelToken()),
      throwsA(
        isA<ImageApiException>()
            .having((error) => error.code, 'code', 'invalidImage')
            .having((error) => error.outputs, 'outputs', [url]),
      ),
    );
    valid = true;
    expect(await client.downloadImages([url], CancelToken()), [png]);
  });

  test(
    'HTTP rejection retains status and message without resubmitting',
    () async {
      var calls = 0;
      handler = (request) async {
        calls++;
        await request.drain<void>();
        request.response.statusCode = 400;
        request.response.write('{"error":{"message":"unsupported model"}}');
        await request.response.close();
      };
      await expectLater(
        client.generate('icon', [], const ImageOptions(), CancelToken()),
        throwsA(
          isA<ImageApiException>()
              .having((e) => e.code, 'code', 'serviceError')
              .having((e) => e.detail, 'detail', contains('HTTP 400')),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'invalid transparency and format fail before a network request',
    () async {
      await expectLater(
        client.generate(
          'icon',
          [],
          const ImageOptions(format: 'jpeg', transparent: true),
          CancelToken(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'SSE accepts fragmented UTF-8, ignores previews, and returns the final image',
    () async {
      final payload =
          ': heartbeat\r\n\r\ndata: {"type":"image_generation.partial_image","b64_json":"preview"}\r\n\r\n'
          'data: {"type":"image_generation.completed","b64_json":"AA==","revised_prompt":"鲸鱼"}\r\n\r\ndata: [DONE]\r\n\r\n';
      final chunks = utf8.encode(payload).map((byte) => [byte]);
      expect(
        await readImageResponse(Stream.fromIterable(chunks), eventStream: true),
        ['data:image/*;base64,AA=='],
      );
    },
  );

  test(
    'SSE does not save an unfinished preview as a successful result',
    () async {
      await expectLater(
        readImageResponse(
          Stream.value(
            utf8.encode(
              'data: {"type":"image_generation.partial_image","b64_json":"AA=="}\n\n',
            ),
          ),
          eventStream: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'SSE propagates server failures and supports gateways returning a final data array',
    () async {
      await expectLater(
        readImageResponse(
          Stream.value(
            utf8.encode('data: {"error":{"message":"generation failed"}}\n\n'),
          ),
          eventStream: true,
        ),
        throwsA(
          isA<ImageApiException>().having(
            (e) => e.detail,
            'detail',
            'generation failed',
          ),
        ),
      );
      expect(
        await readImageResponse(
          Stream.value(
            utf8.encode(
              'data: {"object":"image.generation.result","data":[{"b64_json":"AA=="}]}\n\n',
            ),
          ),
          eventStream: true,
        ),
        ['data:image/*;base64,AA=='],
      );
    },
  );
}
