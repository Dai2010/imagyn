import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/webfetch.dart';
import 'package:imagyn/core/webfetch_tls.dart';

SecurityContext serverContext() => SecurityContext()
  ..useCertificateChain('test/support/webfetch_test_cert.pem')
  ..usePrivateKey('test/support/webfetch_test_key.pem');
SecurityContext clientContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/support/webfetch_test_cert.pem');

void main() {
  test('a connection task returned after timeout is still disposed', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = Completer<void>();
    Socket? accepted;
    server.listen((socket) {
      accepted = socket;
      socket.listen((_) {}, onDone: closed.complete, onError: (Object _) {});
    });
    addTearDown(() async {
      accepted?.destroy();
      await server.close();
    });
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        fetchUrl(
          'http://127.0.0.1:${server.port}/',
          policy: (_) async => InternetAddress.loopbackIPv4,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'fetchTimeout',
          ),
        ),
      );
      await closed.future.timeout(const Duration(seconds: 3));
    }, _DelayedConnection());
  });

  test('total timeout closes a TCP-connected stalled TLS handshake', () async {
    final peer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<void>();
    final closed = Completer<void>();
    Socket? accepted;
    peer.listen((socket) {
      accepted = socket;
      socket.listen(
        (_) {
          if (!connected.isCompleted) connected.complete();
        },
        onDone: closed.complete,
        onError: (Object _) {},
      );
    });
    addTearDown(() async {
      accepted?.destroy();
      await peer.close();
    });
    await expectLater(
      fetchUrl(
        'https://127.0.0.1:${peer.port}/',
        policy: (_) async => InternetAddress.loopbackIPv4,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'fetchTimeout',
        ),
      ),
    );
    await connected.future.timeout(const Duration(seconds: 2));
    await closed.future.timeout(const Duration(seconds: 2));
  });

  test(
    'TLS adapter handles backpressure and duplex data without loss',
    () async {
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext(),
      );
      addTearDown(server.close);
      final payload = List<int>.generate(2 * maxFetchBytes, (i) => i % 251);
      final received = Completer<List<int>>();
      server.listen((socket) async {
        addTearDown(socket.destroy);
        final data = <int>[];
        final subscription = socket.listen(
          (chunk) {
            data.addAll(chunk);
            if (data.length == payload.length) {
              received.complete(data);
              socket.add([7, 8, 9]);
              socket.flush().ignore();
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!received.isCompleted) received.completeError(error, stack);
          },
        );
        subscription.pause();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        subscription.resume();
      });
      final task = await startPinnedTlsConnection(
        InternetAddress.loopbackIPv4,
        Uri.parse('https://localhost:${server.port}/'),
        clientContext(),
      );
      final client = await task.socket;
      addTearDown(client.destroy);
      // This policy address carries only its IP; SNI/certificate verification
      // must still use the request URI's hostname.
      expect((client as SecureSocket).peerCertificate, isNotNull);
      final reply = client.expand((chunk) => chunk).take(3).toList();
      client.add(payload);
      await client.flush();
      expect(
        await received.future.timeout(const Duration(seconds: 10)),
        payload,
      );
      expect(await reply.timeout(const Duration(seconds: 10)), [7, 8, 9]);
    },
  );

  test('large TLS responses enforce the byte cap', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext(),
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.text;
      try {
        request.response.add(List<int>.filled(maxFetchBytes + 65536, 0x61));
        await request.response.close();
      } on Object {
        // The cap closes the client before the complete response is consumed.
      }
    });
    final result = await fetchUrl(
      'https://localhost:${server.port}/',
      policy: (_) async => InternetAddress.loopbackIPv4,
      securityContext: clientContext(),
    );
    expect(result.bytes, maxFetchBytes);
    expect(result.text.length, maxFetchBytes);
    expect(result.truncated, isTrue);
  });

  test('TLS redirects and empty responses close cleanly', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext(),
    );
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, '/empty');
      } else {
        request.response.headers.contentType = ContentType.text;
        request.response.contentLength = 0;
      }
      await request.response.close();
    });
    final result = await fetchUrl(
      'https://localhost:${server.port}/start',
      policy: (_) async => InternetAddress.loopbackIPv4,
      securityContext: clientContext(),
    );
    expect(requests, 2);
    expect(result.url, 'https://localhost:${server.port}/empty');
    expect(result.bytes, 0);
    expect(result.text, isEmpty);
    expect(result.truncated, isFalse);
  });
}

final class _DelayedConnection extends IOOverrides {
  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) async {
    final task = await super.socketStartConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
    );
    await task.socket;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return task;
  }
}
