import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      ..writeln('HTTP: $status · $bytes bytes${truncated ? ' (truncated)' : ''}')
      ..writeln()
      ..write(text);
    return buffer.toString();
  }
}

/// Refuses a host that is not public. Exposed separately so the rule can be
/// tested without a network and injected by callers that already resolved it.
typedef HostPolicy = Future<void> Function(Uri uri);

/// Fetches one public HTTP(S) page and returns readable text.
///
/// Refused on purpose: anything that is not http/https, loopback, private,
/// link-local or carrier-grade NAT addresses (checked on the literal and on
/// every resolved address), and redirects that land on such an address.
Future<FetchResult> fetchUrl(
  String raw, {
  HttpClient? client,
  HostPolicy policy = ensurePublicHost,
}) async {
  var uri = _parse(raw);
  final owned = client == null;
  final http = client ?? HttpClient();
  if (owned) http.connectionTimeout = fetchTimeout;
  // One deadline for the whole operation: `Stream.timeout` only fires when the
  // gap between chunks is too long, so a server dripping one byte every few
  // seconds could otherwise keep the fetch alive forever.
  final deadline = DateTime.now().add(fetchTimeout);
  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) throw const FormatException('fetchTimeout');
    return left;
  }

  try {
    for (var hop = 0; hop <= maxFetchRedirects; hop++) {
      await policy(uri);
      final request = await http.getUrl(uri).timeout(remaining());
      request
        ..followRedirects = false
        ..headers.set(
          HttpHeaders.userAgentHeader,
          'Imagyn/0.1 (+https://github.com/Dai2010/imagyn)',
        );
      final response = await request.close().timeout(remaining());
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await _discard(response);
        if (location == null) {
          throw const FormatException('fetchRedirect');
        }
        uri = uri.resolve(location);
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
      await for (final chunk in response.timeout(remaining())) {
        remaining();
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
  } finally {
    if (owned) http.close(force: true);
  }
}

/// Reads at most a small amount before letting the connection go. A redirect or
/// an error page can be arbitrarily large, and draining it fully is how a
/// rejected response turns into a hang.
Future<void> _discard(HttpClientResponse response) async {
  try {
    await response.take(64 * 1024).drain<void>();
  } on Object {
    // The connection is closed either way.
    return;
  }
}

Uri _parse(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !_isHttp(uri) || uri.host.isEmpty) {
    throw const FormatException('fetchScheme');
  }
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

Future<void> ensurePublicHost(Uri uri) async {
  if (!_isHttp(uri)) throw const FormatException('fetchScheme');
  final host = uri.host.toLowerCase();
  if (host.isEmpty ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    throw const FormatException('fetchPrivate');
  }
  final literal = InternetAddress.tryParse(host);
  final addresses = literal != null
      ? [literal]
      : await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw const FormatException('fetchPrivate');
  for (final address in addresses) {
    if (_isPrivate(address)) throw const FormatException('fetchPrivate');
  }
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
  // IPv6: unspecified, loopback, unique-local and link-local.
  if (bytes.length != 16) return true;
  final startsZero = bytes.take(15).every((value) => value == 0);
  if (startsZero) return true;
  if (bytes[0] & 0xfe == 0xfc) return true;
  if (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) return true;
  // IPv4-mapped (::ffff:a.b.c.d) is checked as its IPv4 tail.
  if (bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
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
  var text = html
      .replaceAll(
        RegExp(r'<(script|style|noscript)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
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
  return text.replaceAll(RegExp(r'[ \t\r\f]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
