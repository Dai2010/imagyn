import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/webfetch.dart';

void main() {
  late HttpServer server;
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await handler(request);
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<InternetAddress> allowAll(Uri _) async =>
      InternetAddress.loopbackIPv4;

  test('refuses schemes and literal hosts that are not public', () async {
    for (final url in [
      'ftp://example.com/file',
      'http://127.0.0.1/',
      'http://10.0.0.5/',
      'http://172.16.0.1/',
      'http://192.168.1.1/',
      'http://169.254.169.254/',
      'http://localhost/',
      'http://[::1]/',
    ]) {
      await expectLater(
        ensurePublicHost(Uri.parse(url)),
        throwsA(isA<FormatException>()),
        reason: url,
      );
    }
  });

  test('checks the address on every redirect hop', () async {
    var hops = 0;
    handler = (request) async {
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/next');
      await request.response.close();
    };
    await expectLater(
      fetchUrl(
        'http://127.0.0.1:${server.port}/start',
        policy: (uri) async {
          hops++;
          if (hops > 1) throw const FormatException('fetchPrivate');
          return InternetAddress.loopbackIPv4;
        },
      ),
      throwsA(isA<FormatException>()),
    );
    // The second hop is refused before its request is sent.
    expect(hops, 2);
  });

  test('reports the final address and readable text', () async {
    handler = (request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, '/final');
      } else {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<html><script>bad()</script><h1>Hello</h1>'
          '<p>World &amp; more</p></html>',
        );
      }
      await request.response.close();
    };
    final result = await fetchUrl(
      'http://127.0.0.1:${server.port}/start',
      policy: allowAll,
    );
    expect(result.url, 'http://127.0.0.1:${server.port}/final');
    expect(result.text, contains('Hello'));
    expect(result.text, contains('World & more'));
    expect(result.text, isNot(contains('bad()')));
    expect(result.asToolResult(), contains('URL:'));
  });

  test('stops reading at the byte cap and says so', () async {
    final payload = List<int>.filled(maxFetchBytes + 4096, 0x61);
    handler = (request) async {
      request.response.headers.contentType = ContentType.text;
      try {
        request.response.add(payload);
        await request.response.close();
      } on Object {
        // The client stops reading at the cap; a broken pipe here is expected.
        return;
      }
    };
    final result = await fetchUrl(
      'http://127.0.0.1:${server.port}/big',
      policy: allowAll,
    );
    expect(result.bytes, maxFetchBytes);
    expect(result.truncated, isTrue);
    expect(result.asToolResult(), contains('truncated'));
  });

  test('refuses a body that is not readable text', () async {
    handler = (request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([1, 2, 3]);
      await request.response.close();
    };
    await expectLater(
      fetchUrl('http://127.0.0.1:${server.port}/img', policy: allowAll),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'fetchContentType',
        ),
      ),
    );
  });

  test('gives up on an endless redirect chain', () async {
    handler = (request) async {
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/again');
      await request.response.close();
    };
    await expectLater(
      fetchUrl('http://127.0.0.1:${server.port}/loop', policy: allowAll),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'fetchRedirects',
        ),
      ),
    );
  });

  test('the tool result is clipped for the context window', () {
    final result = FetchResult(
      url: 'https://example.com/',
      status: 200,
      bytes: maxFetchChars * 2,
      text: 'x' * (maxFetchChars * 2),
      truncated: false,
    );

    final text = result.asToolResult();

    expect(text, contains('[truncated]'));
    expect(text, contains('(truncated)'));
    expect(text.length, lessThan(maxFetchChars + 200));
  });
}
