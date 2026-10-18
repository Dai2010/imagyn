import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/webfetch.dart';

Matcher fetchError(String message) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', message),
);

void main() {
  group('public destination policy', () {
    test('rejects IPv6 non-public and embedded private destinations', () async {
      for (final host in [
        '::', '::1', 'fc00::1', 'fdff::1', 'fe80::1', 'febf::1',
        'fec0::1', 'feff::1', 'ff00::1', 'ff02::1', 'ff0e::1', 'ffff::1',
        '::127.0.0.1', '::7f00:1', '::10.0.0.1', '::a00:1',
        '::169.254.169.254', '::a9fe:a9fe', '::100.64.0.1',
        '::ffff:127.0.0.1', '::ffff:7f00:1', '::ffff:10.0.0.1',
        '::ffff:169.254.169.254', '::ffff:192.168.1.1',
        '::ffff:0:127.0.0.1', '::ffff:0:a9fe:a9fe',
        '64:ff9b::127.0.0.1', '64:ff9b::a9fe:a9fe',
        '64:ff9b::808:808', // Strict policy also excludes public NAT64 tails.
        '64:ff9b:1::1', '64:ff9b:1:1234:5678:9abc:def0:1234',
      ]) {
        await expectLater(
          ensurePublicHost(Uri.parse('http://[$host]/')),
          fetchError('fetchPrivate'),
          reason: host,
        );
      }
    });

    test('retains native public IPv4/IPv6 and public mapped tails', () async {
      for (final host in [
        '8.8.8.8', '1.1.1.1', '100.63.255.255', '100.128.0.1',
        '172.15.255.255', '172.32.0.1',
        '2606:4700:4700::1111', '2001:4860:4860::8888',
        // A native public IPv6 suffix is not an embedded IPv4 destination.
        '2606:4700::a00:1', '2606:4700::a9fe:a9fe',
        '::8.8.8.8', '::808:808', '::ffff:8.8.8.8', '::ffff:808:808',
        '::ffff:0:8.8.8.8',
      ]) {
        final address = InternetAddress(host);
        final uri = Uri(scheme: 'https', host: host, path: '/');
        final approved = await ensurePublicHost(uri);
        expect(approved.rawAddress, address.rawAddress, reason: host);
      }
    });

    test('all IPv4 deny rules also apply to embedded forms', () async {
      for (final ipv4 in [
        '0.0.0.2',
        '10.0.0.1',
        '127.255.255.255',
        '169.254.0.1',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.0.1',
        '100.64.0.1',
        '100.127.255.255',
        '192.0.0.1',
        '224.0.0.1',
        '255.255.255.255',
      ]) {
        for (final host in [ipv4, '::$ipv4', '::ffff:$ipv4']) {
          await expectLater(
            ensurePublicHost(Uri(scheme: 'http', host: host)),
            fetchError('fetchPrivate'),
            reason: host,
          );
        }
      }
    });

    test(
      'checks every DNS answer, including mixed public/private sets',
      () async {
        final uri = Uri.parse('https://page.example/');
        for (final blocked in [
          '127.0.0.1',
          'ff02::1',
          '::a9fe:a9fe',
          '::ffff:7f00:1',
          '64:ff9b::a9fe:a9fe',
          '64:ff9b:1::1',
        ]) {
          for (final answers in [
            ['8.8.8.8', blocked],
            [blocked, '2606:4700:4700::1111'],
          ]) {
            await expectLater(
              ensurePublicHost(
                uri,
                lookup: (_) async => answers.map(InternetAddress.new).toList(),
              ),
              fetchError('fetchPrivate'),
              reason: answers.toString(),
            );
          }
        }
        await expectLater(
          ensurePublicHost(uri, lookup: (_) async => []),
          fetchError('fetchPrivate'),
        );
        final approved = await ensurePublicHost(
          uri,
          lookup: (host) async {
            expect(host, 'page.example');
            return [
              InternetAddress('8.8.8.8'),
              InternetAddress('2606:4700::1111'),
            ];
          },
        );
        expect(approved.address, '8.8.8.8');
      },
    );

    test('rejects local names with trailing dots before DNS', () async {
      for (final host in [
        'localhost',
        'LOCALHOST.',
        'a.localhost.',
        'device.local.',
        'service.internal.',
        'local',
        'internal',
      ]) {
        await expectLater(
          ensurePublicHost(
            Uri(scheme: 'http', host: host),
            lookup: (_) async {
              fail('local name reached DNS: $host');
            },
          ),
          fetchError('fetchPrivate'),
        );
      }
    });
  });

  group('fetch connection boundary', () {
    late HttpServer server;
    late Future<void> Function(HttpRequest) handler;
    late List<HttpRequest> requests;
    final pendingBodies = <Completer<void>>[];

    setUp(() async {
      requests = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request);
        await handler(request);
      });
    });
    tearDown(() async {
      for (final gate in pendingBodies) {
        if (!gate.isCompleted) gate.complete();
      }
      pendingBodies.clear();
      await server.close(force: true);
    });
    Future<InternetAddress> localPolicy(Uri _) async =>
        InternetAddress.loopbackIPv4;
    String url([String path = '/']) =>
        'http://unresolvable.invalid:${server.port}$path';

    test('pins the approved IP and preserves Host across redirects', () async {
      final policies = <String>[];
      handler = (request) async {
        expect(request.headers.host, 'unresolvable.invalid');
        expect(request.headers.port, server.port);
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
        if (request.uri.path == '/') {
          request.response.statusCode = 302;
          request.response.cookies.add(Cookie('secret', 'value'));
          request.response.headers.set(HttpHeaders.locationHeader, '/final');
        } else {
          request.response.headers.contentType = ContentType.text;
          request.response.write('pinned');
        }
        await request.response.close();
      };
      final result = await fetchUrl(
        url(),
        policy: (uri) async {
          policies.add(uri.path);
          return InternetAddress.loopbackIPv4;
        },
      );
      expect(result.text, 'pinned');
      expect(result.url, url('/final'));
      expect(policies, ['/', '/final']);
      expect(requests, hasLength(2));
    });

    test('ignores environment proxies for pinned direct connections', () async {
      var proxyLookups = 0;
      handler = (request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('direct');
        await request.response.close();
      };
      final result = await HttpOverrides.runZoned(
        () => fetchUrl(url(), policy: localPolicy),
        findProxyFromEnvironment: (uri, environment) {
          proxyLookups++;
          return 'PROXY 127.0.0.1:1';
        },
      );
      expect(result.text, 'direct');
      expect(proxyLookups, 0);
    });

    test('HTTPS refuses a plaintext HTTP peer', () async {
      final peer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(peer.close);
      final firstByte = Completer<int>();
      peer.listen((socket) {
        addTearDown(socket.destroy);
        socket.listen((data) {
          if (!firstByte.isCompleted) firstByte.complete(data.first);
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
            'Content-Length: 2\r\nConnection: close\r\n\r\nok',
          );
          socket.close();
        }, onError: (Object _) {});
      });
      await expectLater(
        fetchUrl('https://127.0.0.1:${peer.port}/', policy: localPolicy),
        throwsA(isA<TlsException>()),
      );
      expect(
        await firstByte.future,
        0x16,
      ); // TLS handshake record, ClientHello.
    });

    test('default policy rejects a private socket before connecting', () async {
      await expectLater(
        fetchUrl('http://127.0.0.1:${server.port}/'),
        fetchError('fetchPrivate'),
      );
      expect(requests, isEmpty);
    });

    test('refuses userinfo before policy or transport is reached', () async {
      await expectLater(
        fetchUrl(
          'http://user:secret@unresolvable.invalid:${server.port}/',
          policy: (_) async {
            fail('userinfo reached policy');
          },
        ),
        fetchError('fetchCredentials'),
      );
      expect(requests, isEmpty);
    });

    for (final target in [
      'http://127.0.0.1/',
      'http://[ff02::1]/',
      'http://[::a9fe:a9fe]/',
      'http://[::ffff:7f00:1]/',
      'http://[64:ff9b::a9fe:a9fe]/',
      'http://[64:ff9b:1::1]/',
    ]) {
      test('rechecks redirected destination $target', () async {
        var calls = 0;
        handler = (request) async {
          request.response.statusCode = 302;
          request.response.headers.set(HttpHeaders.locationHeader, target);
          await request.response.close();
        };
        await expectLater(
          fetchUrl(
            url(),
            policy: (uri) async {
              calls++;
              if (calls == 1) return InternetAddress.loopbackIPv4;
              return ensurePublicHost(uri);
            },
          ),
          fetchError('fetchPrivate'),
        );
        expect(calls, 2);
        expect(requests, hasLength(1));
      });
    }

    for (final target in [
      'ftp://example.com/',
      'http://user:pass@example.com/',
    ]) {
      test(
        'validates redirected URL syntax with a custom policy: $target',
        () async {
          var calls = 0;
          handler = (request) async {
            request.response.statusCode = 302;
            request.response.headers.set(HttpHeaders.locationHeader, target);
            await request.response.close();
          };
          await expectLater(
            fetchUrl(
              url(),
              policy: (uri) async {
                calls++;
                return InternetAddress.loopbackIPv4;
              },
            ),
            fetchError(
              target.startsWith('ftp') ? 'fetchScheme' : 'fetchCredentials',
            ),
          );
          expect(calls, 1);
          expect(requests, hasLength(1));
        },
      );
    }

    test(
      'a late policy result cannot connect after the total deadline',
      () async {
        final policyResult = Completer<InternetAddress>();
        await expectLater(
          fetchUrl(
            url(),
            policy: (_) => policyResult.future,
            timeout: const Duration(milliseconds: 200),
          ),
          fetchError('fetchTimeout'),
        );
        policyResult.complete(InternetAddress.loopbackIPv4);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(requests, isEmpty);
      },
    );

    test('a dripping body cannot extend the total deadline', () async {
      var stop = false;
      handler = (request) async {
        request.response.headers.contentType = ContentType.text;
        try {
          while (!stop) {
            request.response.write('x');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } on Object {
          // Timeout closes the connection while the server is still writing.
        }
      };
      try {
        await expectLater(
          fetchUrl(
            url(),
            policy: localPolicy,
            timeout: const Duration(milliseconds: 300),
          ),
          fetchError('fetchTimeout'),
        );
      } finally {
        stop = true;
      }
    });

    for (final status in [302, 404, 200]) {
      test('cancels an unending rejected body (status $status)', () async {
        handler = (request) async {
          if (request.uri.path == '/final') {
            request.response.headers.contentType = ContentType.text;
            request.response.write('done');
            await request.response.close();
            return;
          }
          request.response.statusCode = status;
          request.response.headers.contentType = ContentType('image', 'png');
          if (status == 302) {
            request.response.headers.set(HttpHeaders.locationHeader, '/final');
          }
          request.response.write('unending');
          final gate = Completer<void>();
          pendingBodies.add(gate);
          try {
            await request.response.flush();
            await gate.future;
            await request.response.close();
          } on Object {
            // Fetch cancels the unwanted body without waiting for EOF.
          }
        };
        final result = fetchUrl(
          url(),
          policy: localPolicy,
          timeout: const Duration(seconds: 2),
        );
        if (status == 302) {
          expect((await result).text, 'done');
        } else {
          await expectLater(
            result,
            fetchError(status == 404 ? 'fetchStatus 404' : 'fetchContentType'),
          );
        }
      });
    }
  });

  test('pinned HTTPS preserves certificate hostname verification', () async {
    // Public fixtures for tests only; this key has no production use.
    final cert = File('test/support/webfetch_test_cert.pem').readAsBytesSync();
    final key = File('test/support/webfetch_test_key.pem').readAsBytesSync();
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(cert)
      ..usePrivateKeyBytes(key);
    final clientContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(cert);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.headers.host, 'localhost');
      request.response.headers.contentType = ContentType.text;
      request.response.write('verified');
      await request.response.close();
    });
    Future<InternetAddress> policy(Uri uri) async =>
        InternetAddress.tryParse(uri.host) ??
        (await InternetAddress.lookup(
          uri.host,
          type: InternetAddressType.IPv4,
        )).first;
    final result = await fetchUrl(
      'https://localhost:${server.port}/',
      policy: policy,
      securityContext: clientContext,
    );
    expect(result.text, 'verified');
    await expectLater(
      fetchUrl(
        'https://127.0.0.1:${server.port}/',
        policy: policy,
        securityContext: clientContext,
      ),
      throwsA(isA<HandshakeException>()),
    );
    // The default client still refuses a certificate outside trusted roots.
    await expectLater(
      fetchUrl('https://localhost:${server.port}/', policy: policy),
      throwsA(isA<HandshakeException>()),
    );
    expect(requests, 1);
  });

  test('HTML cleanup consumes unclosed hostile markup through EOF', () {
    for (final token in ['<script>', '<style>', '<noscript>', '<!--', '<']) {
      final watch = Stopwatch()..start();
      expect(htmlToText(token * (maxFetchBytes ~/ token.length)), isEmpty);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: token,
      );
    }
    expect(htmlToText('before<script>hidden'), 'before');
    expect(htmlToText('before<!--hidden'), 'before');
    expect(
      htmlToText('<script>x</script ><p>visible &amp; text</p>'),
      'visible & text',
    );
    expect(htmlToText('<scripted>visible</scripted>'), 'visible');
  });
}
