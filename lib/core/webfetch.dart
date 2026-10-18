import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'webfetch_tls.dart';

/// Largest body the app is willing to keep from one page. A model does not need
/// more than this to answer, and an unbounded read on a phone is how a redirect
/// loop or a large file turns into an out-of-memory kill.
const maxFetchBytes = 1024 * 1024;

/// Redirects are followed by hand so every hop can be checked again; a public
/// URL that redirects to a private address must not slip through.
const maxFetchRedirects = 3;

const fetchTimeout = Duration(seconds: 15);

/// The text one `fetch_url` call produces. `url` is the address that actually
/// answered after redirects, so the card can show where the text came from.
class FetchResult {
  const FetchResult({
    required this.url,
    required this.status,
    required this.bytes,
    required this.text,
    required this.truncated,
  });
  final String url;
  final int status;
  final int bytes;
  final String text;
  final bool truncated;

  /// What the model receives. The header states the source and the size so a
  /// truncated page is never mistaken for the whole document.
  String asToolResult() {
    final buffer = StringBuffer()
      ..writeln('URL: $url')
      ..writeln(
        'HTTP: $status · $bytes bytes${truncated ? ' (truncated)' : ''}',
      )
      ..writeln()
      ..write(text);
    return buffer.toString();
  }
}

/// A trusted application override of the destination policy. Returning an
/// address authorizes that exact socket destination, including private IPs.
/// Never derive this callback from tool arguments or fetched page content.
typedef HostPolicy = Future<InternetAddress> Function(Uri uri);

typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// Fetches one public HTTP(S) page and returns readable text.
///
/// Refused on purpose: anything that is not http/https, loopback, private,
/// link-local or carrier-grade NAT addresses (checked on the literal and on
/// every resolved address), and redirects that land on such an address.
Future<FetchResult> fetchUrl(
  String raw, {
  HostPolicy policy = ensurePublicHost,
  Duration timeout = fetchTimeout,
  SecurityContext? securityContext,
}) async {
  var uri = _parse(raw);
  // A shared client can reuse sockets or credentials established before this
  // policy ran. Own a fresh client so all connections cross the same boundary.
  final http = HttpClient(context: securityContext)
    ..connectionTimeout = timeout
    ..findProxy = (_) => 'DIRECT';
  // The address the policy approved, pinned for the connection that follows.
  // Without this, HttpClient resolves the name a second time and a DNS answer
  // that changed in between can point the request at a private address.
  final pinned = <String, InternetAddress>{};
  final connections = <ConnectionTask<Socket>>{};
  var finished = false;
  void cancelConnection(ConnectionTask<Socket> task) {
    task.cancel();
    // A task may have connected just before cancellation. Dispose the socket
    // even when the SDK task's cancel callback only cancels pending TCP work.
    task.socket
        .then<void>((socket) => socket.destroy(), onError: (Object _) {})
        .ignore();
  }

  http.connectionFactory = (url, proxyHost, proxyPort) async {
    if (finished) throw const FormatException('fetchTimeout');
    if (proxyHost != null) throw const FormatException('fetchProxy');
    final address = pinned[url.host];
    if (address == null) throw const FormatException('fetchPrivate');
    final task = url.scheme == 'https'
        ? await startPinnedTlsConnection(address, url, securityContext)
        : await Socket.startConnect(address, url.port);
    if (finished) {
      cancelConnection(task);
      throw const FormatException('fetchTimeout');
    }
    connections.add(task);
    return task;
  };

  Future<FetchResult> run() async {
    for (var hop = 0; hop <= maxFetchRedirects; hop++) {
      pinned[uri.host] = await policy(uri);
      // Future.timeout does not cancel a pending DNS/policy future. A late
      // answer must never start a request after the caller has timed out.
      if (finished) throw const FormatException('fetchTimeout');
      final request = await http.getUrl(uri);
      request
        ..followRedirects = false
        ..persistentConnection = false
        ..headers.set(
          HttpHeaders.userAgentHeader,
          'Imagyn/0.1 (+https://github.com/Dai2010/imagyn)',
        );
      final response = await request.close();
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await _discard(response);
        if (location == null) {
          throw const FormatException('fetchRedirect');
        }
        uri = _parse(uri.resolve(location).toString());
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _discard(response);
        throw FormatException('fetchStatus ${response.statusCode}');
      }
      final type = response.headers.contentType?.mimeType.toLowerCase() ?? '';
      if (!_readable(type)) {
        await _discard(response);
        throw const FormatException('fetchContentType');
      }
      final bytes = <int>[];
      var truncated = false;
      await for (final chunk in response) {
        final room = maxFetchBytes - bytes.length;
        if (chunk.length > room) {
          bytes.addAll(chunk.take(room));
          truncated = true;
          break;
        }
        bytes.addAll(chunk);
      }
      final charset = response.headers.contentType?.charset ?? 'utf-8';
      var text = _decode(bytes, charset);
      if (type == 'text/html' || type == 'application/xhtml+xml') {
        text = htmlToText(text);
      }
      return FetchResult(
        url: uri.toString(),
        status: response.statusCode,
        bytes: bytes.length,
        text: text.trim(),
        truncated: truncated,
      );
    }
    throw const FormatException('fetchRedirects');
  }

  try {
    // Includes DNS/policy, all redirects, headers, and body reads. An inactivity
    // timeout alone can be extended indefinitely by a slow streaming response.
    return await run().timeout(
      timeout,
      onTimeout: () => throw const FormatException('fetchTimeout'),
    );
  } finally {
    finished = true;
    for (final task in connections) {
      cancelConnection(task);
    }
    http.close(force: true);
  }
}

/// Cancel unwanted bodies immediately. Stream.take counts chunks, not bytes;
/// draining an attacker-controlled response can consume unbounded time/data.
Future<void> _discard(HttpClientResponse response) async {
  await response.listen(null).cancel();
}

Uri _parse(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !_isHttp(uri) || uri.host.isEmpty) {
    throw const FormatException('fetchScheme');
  }
  // HttpClient automatically turns URL userinfo into Basic Authorization.
  if (uri.userInfo.isNotEmpty) throw const FormatException('fetchCredentials');
  return uri;
}

bool _isHttp(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

bool _readable(String mime) =>
    mime == 'text/html' ||
    mime == 'application/xhtml+xml' ||
    mime == 'text/plain' ||
    mime == 'application/json' ||
    mime == 'text/markdown' ||
    mime == 'text/xml' ||
    mime == 'application/xml';

Future<InternetAddress> ensurePublicHost(
  Uri uri, {
  HostLookup lookup = InternetAddress.lookup,
}) async {
  _parse(uri.toString());
  final host = uri.host.toLowerCase();
  final name = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  if (host.isEmpty ||
      name == 'localhost' ||
      name == 'local' ||
      name == 'internal' ||
      name.endsWith('.localhost') ||
      name.endsWith('.local') ||
      name.endsWith('.internal')) {
    throw const FormatException('fetchPrivate');
  }
  final literal = InternetAddress.tryParse(host);
  final addresses = literal != null ? [literal] : await lookup(host);
  if (addresses.isEmpty) throw const FormatException('fetchPrivate');
  for (final address in addresses) {
    if (_isPrivate(address)) throw const FormatException('fetchPrivate');
  }
  return addresses.first;
}

bool _isPrivate(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final a = bytes[0], b = bytes[1];
    if (a == 0 || a == 10 || a == 127) return true;
    if (a == 169 && b == 254) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    if (a == 192 && b == 0 && bytes[2] == 0) return true;
    if (a >= 224) return true;
    return false;
  }
  // IPv6: unspecified, loopback, unique-local, link/site-local and multicast.
  if (bytes.length != 16) return true;
  final startsZero = bytes.take(15).every((value) => value == 0);
  if (startsZero) return true;
  if (bytes[0] & 0xfe == 0xfc) return true;
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) >= 0x80) return true;
  if (bytes[0] == 0xff) return true;
  // Deny known NAT64 prefixes: RFC 6052 WKP /96 and RFC 8215 local-use /48.
  // Translation is deliberately outside this public-destination policy.
  if (bytes[0] == 0 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      ((bytes[4] == 0 && bytes[5] == 1) ||
          bytes.sublist(4, 12).every((value) => value == 0))) {
    return true;
  }
  // IPv4-mapped and deprecated IPv4-compatible forms use the IPv4 policy.
  // Compare bytes so hexadecimal and dotted-decimal spellings behave alike.
  final compatible = bytes.take(12).every((value) => value == 0);
  final mapped =
      bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  final translated =
      bytes.take(8).every((value) => value == 0) &&
      bytes[8] == 0xff &&
      bytes[9] == 0xff &&
      bytes[10] == 0 &&
      bytes[11] == 0;
  if (compatible || mapped || translated) {
    return _isPrivate(InternetAddress.fromRawAddress(bytes.sublist(12)));
  }
  return false;
}

String _decode(List<int> bytes, String charset) {
  final name = charset.toLowerCase();
  if (name == 'iso-8859-1' || name == 'latin1' || name == 'windows-1252') {
    return latin1.decode(bytes, allowInvalid: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// A deliberately small HTML reduction: drop scripts and styles, turn tags into
/// spaces, and decode the few entities that otherwise read as noise. The model
/// gets text, not a DOM, and the raw page is never trusted as instructions.
String htmlToText(String html) {
  var text = html.replaceAll(
    RegExp(
      // Each alternative consumes through its terminator or EOF. Without
      // EOF alternatives, repeated unclosed tags cause quadratic rescans
      // on attacker-controlled HTML and block the isolate's deadline timer.
      r'<!--[\s\S]*?(?:-->|$)|'
      r'<(script|style|noscript)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)|'
      r'<[^>]*(?:>|$)',
      caseSensitive: false,
    ),
    ' ',
  );
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&#x27;': "'",
  };
  entities.forEach((from, to) => text = text.replaceAll(from, to));
  return text
      .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
