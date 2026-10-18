// Local-only diagnostic. Exit 1 means a timed-out TLS handshake retained its
// underlying connection. This is a merge-blocking resource boundary check.
import 'dart:async';
import 'dart:io';

import 'package:imagyn/core/webfetch.dart';

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final connected = Completer<void>();
  final closed = Completer<void>();
  Socket? peer;
  server.listen((socket) {
    peer = socket;
    socket.listen(
      (_) {
        if (!connected.isCompleted) connected.complete();
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {},
    );
  });
  try {
    try {
      await fetchUrl(
        'https://127.0.0.1:${server.port}/',
        policy: (_) async => InternetAddress.loopbackIPv4,
        timeout: const Duration(milliseconds: 500),
      );
      throw StateError('stalled TLS peer unexpectedly answered');
    } on FormatException catch (error) {
      if (error.message != 'fetchTimeout') rethrow;
    }
    await connected.future.timeout(const Duration(seconds: 2));
    try {
      await closed.future.timeout(const Duration(seconds: 1));
      stdout.writeln('PASS: timed-out TLS connection closed');
    } on TimeoutException {
      stderr.writeln('FAIL: TLS connection remains open after fetchTimeout');
      exitCode = 1;
    }
  } finally {
    peer?.destroy();
    await server.close();
  }
}
