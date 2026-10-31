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

/// What one call may put into the conversation. The byte cap protects memory;
/// this one protects the context window, which is far smaller than the body a
/// page can have.
const maxFetchChars = 20000;

/// How the page is reduced before the model sees it. Markdown keeps headings,
/// lists and links, which is also the shape a server-side fetcher returns, so
/// both paths hand the model the same thing.
enum FetchFormat { markdown, text }

/// The text one `fetch_url` call produces. `url` is the address that actually
/// answered after redirects, so the card can show where the text came from.
class FetchResult {
  const FetchResult({
    required this.url,
    required this.status,
    required this.bytes,
    required this.text,
    required this.truncated,
    this.title = '',
    this.format = FetchFormat.markdown,
    this.server = false,
  });
  final String url;
  final int status;
  final int bytes;
  final String text;
  final bool truncated;

  /// The document title when the page carries one; empty otherwise, and
  /// always empty on the plain-text path.
  final String title;
  final FetchFormat format;

  /// True when the service did the fetching and returned Markdown, rather than
  /// the app downloading the page itself.
  final bool server;

  /// What the model receives. The header states the source and the size so a
  /// truncated page is never mistaken for the whole document.
  String asToolResult({int maxChars = maxFetchChars}) {
    final runes = text.runes.toList();
    final clipped = runes.length > maxChars;
    final body = clipped
        ? '${String.fromCharCodes(runes.take(maxChars))}\n\n[truncated]'
        : text;
    final buffer = StringBuffer()..writeln('URL: $url');
    if (title.isNotEmpty) buffer.writeln('TITLE: $title');
    buffer
      ..writeln(
        'HTTP: $status · $bytes bytes · '
        '${format == FetchFormat.markdown ? 'markdown' : 'text'}'
        '${server ? ' · fetched by the service' : ''}'
        '${truncated || clipped ? ' (truncated)' : ''}',
      )
      ..writeln()
      ..write(body);
    return buffer.toString();
  }
}

/// Refuses a host that is not public. Exposed separately so the rule can be
/// tested without a network and injected by callers that already resolved it.
typedef HostPolicy = Future<InternetAddress> Function(Uri uri);

/// Fetches one public HTTP(S) page and returns readable text.
///
/// Refused on purpose: anything that is not http/https, loopback, private,
/// link-local or carrier-grade NAT addresses (checked on the literal and on
/// every resolved address), and redirects that land on such an address.
Future<FetchResult> fetchUrl(
  String raw, {
  HttpClient? client,
  HostPolicy policy = ensurePublicHost,
  FetchFormat format = FetchFormat.markdown,
}) async {
  var uri = _parse(raw);
  final owned = client == null;
  final http = client ?? HttpClient();
  if (owned) http.connectionTimeout = fetchTimeout;
  // The address the policy approved, pinned for the connection that follows.
  // Without this, HttpClient resolves the name a second time and a DNS answer
  // that changed in between can point the request at a private address.
  final pinned = <String, InternetAddress>{};
  if (owned) {
    http.connectionFactory = (url, proxyHost, proxyPort) {
      if (proxyHost != null) throw const FormatException('fetchProxy');
      final address = pinned[url.host];
      if (address == null) throw const FormatException('fetchPrivate');
      return Socket.startConnect(address, url.port);
    };
  }
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
      pinned[uri.host] = await policy(uri);
      final request = await http.getUrl(uri).timeout(remaining());
      request
        ..followRedirects = false
        ..headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (compatible; Imagyn/0.2; +https://github.com/Dai2010/imagyn)',
        )
        // Servers that render two versions pick the one the client asks for;
        // asking for Markdown first is what makes the plain path usable too.
        ..headers.set(
          HttpHeaders.acceptHeader,
          format == FetchFormat.markdown
              ? 'text/markdown;q=1.0, text/x-markdown;q=0.9, '
                    'text/plain;q=0.8, text/html;q=0.7, */*;q=0.1'
              : 'text/plain;q=1.0, text/markdown;q=0.9, '
                    'text/html;q=0.8, */*;q=0.1',
        )
        ..headers.set(
          HttpHeaders.acceptLanguageHeader,
          'zh-CN,zh;q=0.9,en;q=0.8',
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
      var title = '';
      if (type == 'text/html' || type == 'application/xhtml+xml') {
        title = htmlTitle(text);
        text = format == FetchFormat.markdown
            ? htmlToMarkdown(text, uri)
            : htmlToText(text);
      }
      return FetchResult(
        url: uri.toString(),
        status: response.statusCode,
        bytes: bytes.length,
        text: text.trim(),
        truncated: truncated,
        title: title,
        format: format,
      );
    }
    throw const FormatException('fetchRedirects');
  } on FormatException {
    rethrow;
  } on SocketException catch (error) {
    // The operating system knows which of these it was; the message alone
    // ("Connection failed") does not, and the two cases point at opposite
    // places to look: a closed port versus a server that never answered.
    throw FormatException(_socketCode(error));
  } on HandshakeException {
    throw const FormatException('fetchTls');
  } on TlsException {
    throw const FormatException('fetchTls');
  } on TimeoutException {
    throw const FormatException('fetchTimeout');
  } on HttpException {
    throw const FormatException('fetchHttp');
  } finally {
    if (owned) http.close(force: true);
  }
}

/// The failure a socket error names, in the form the tool reports it.
String _socketCode(SocketException error) {
  final code = error.osError?.errorCode;
  final text =
      '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  if (text.contains('refused') || code == 111 || code == 61) {
    return 'fetchRefused';
  }
  if (text.contains('host lookup') ||
      text.contains('name or service not known') ||
      text.contains('nodename nor servname') ||
      code == 7 ||
      code == 8) {
    return 'fetchDns';
  }
  if (text.contains('reset') || code == 104 || code == 54) {
    return 'fetchReset';
  }
  if (text.contains('timed out') || code == 110) {
    return 'fetchTimeout';
  }
  if (text.contains('unreachable') || code == 101 || code == 113) {
    return 'fetchUnreachable';
  }
  return code == null ? 'fetchSocket' : 'fetchSocket $code';
}

/// Whether a failed fetch is worth a second attempt through the service.
///
/// Only a page that answered but refused this client (403) or asked it to slow
/// down (429) qualifies. A missing page, a private address or a timeout is
/// answered from the app's own attempt: retrying those elsewhere would report
/// another server's view of the page instead of what it told us.
bool fetchWantsService(String code) =>
    code == 'fetchStatus 403' || code == 'fetchStatus 429';

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

Future<InternetAddress> ensurePublicHost(Uri uri) async {
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
  final text = html
      .replaceAll(
        RegExp(r'<(script|style|noscript)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  return decodeEntities(text)
      .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// The document title, or an empty string when the page has none.
String htmlTitle(String html) {
  final match = RegExp(
    r'<title[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  if (match == null) return '';
  return decodeEntities(match.group(1) ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Turns a page into Markdown: headings, lists, code, quotes, links and the
/// table rows that survive as pipe-separated lines.
///
/// The reduction is deliberately shallow. A model needs the structure of an
/// article, not a faithful copy of the DOM, and anything invented here is text
/// the page never said.
String htmlToMarkdown(String html, Uri base) {
  final blocks = <String>[];
  String keep(String value) {
    blocks.add(value);
    return '\u0000${blocks.length - 1}\u0000';
  }

  var text = html
      .replaceAll(
        RegExp(
          r'<(script|style|noscript|template|svg|head)[^>]*>[\s\S]*?</\1>',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');

  // Code keeps its own whitespace, so it is pulled out before any tag becomes
  // a line break. A fence inside the code would end the block early, hence the
  // tilde fallback.
  text = text.replaceAllMapped(
    RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false),
    (match) {
      final code = decodeEntities(
        (match.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), ''),
      ).trimRight();
      if (code.trim().isEmpty) return ' ';
      final fence = code.contains('```') ? '~~~' : '```';
      return keep('\n\n$fence\n$code\n$fence\n\n');
    },
  );

  text = text.replaceAllMapped(
    RegExp(r'<code[^>]*>([\s\S]*?)</code>', caseSensitive: false),
    (match) {
      final code = decodeEntities(
        (match.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), ''),
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      return code.isEmpty ? '' : '`$code`';
    },
  );

  text = text
      .replaceAllMapped(
        RegExp(r'<h([1-6])[^>]*>', caseSensitive: false),
        (match) => '\n\n${'#' * int.parse(match.group(1)!)} ',
      )
      .replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n- ')
      .replaceAll(RegExp(r'</li>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?(ul|ol)[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<hr[^>]*>', caseSensitive: false), '\n\n---\n\n')
      .replaceAll(RegExp(r'<blockquote[^>]*>', caseSensitive: false), '\n\n> ')
      .replaceAll(RegExp(r'</blockquote>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<tr[^>]*>', caseSensitive: false), '\n| ')
      .replaceAll(RegExp(r'</t[dh]>', caseSensitive: false), ' | ')
      .replaceAll(RegExp(r'<table[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'</table>', caseSensitive: false), '\n\n')
      .replaceAll(
        RegExp(
          r'</?(div|section|article|header|footer|main|aside|nav|figure)[^>]*>',
          caseSensitive: false,
        ),
        '\n',
      )
      // The optional attribute group has to start with a space: without it
      // `<b…>` also swallows `<body>` and `<i…>` eats `<img …>`.
      .replaceAll(RegExp(r'<(strong|b)(\s[^>]*)?>', caseSensitive: false), '**')
      .replaceAll(RegExp(r'</(strong|b)>', caseSensitive: false), '**')
      .replaceAll(RegExp(r'<(em|i)(\s[^>]*)?>', caseSensitive: false), '*')
      .replaceAll(RegExp(r'</(em|i)>', caseSensitive: false), '*');

  text = text.replaceAllMapped(
    RegExp(r"""<a\b[^>]*href\s*=\s*["']([^"']*)["'][^>]*>([\s\S]*?)</a>""",
        caseSensitive: false),
    (match) {
      final href = _absolute(match.group(1) ?? '', base);
      final label = (match.group(2) ?? '')
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (href.isEmpty || label.isEmpty) return label;
      if (label == href) return '<$href>';
      return '[$label]($href)';
    },
  );

  text = text.replaceAllMapped(
    RegExp(r'<img\b[^>]*>', caseSensitive: false),
    (match) {
      final tag = match.group(0) ?? '';
      final src = _attribute(tag, 'src');
      final alt = _attribute(tag, 'alt');
      if (src.isEmpty) return alt;
      return '![${alt.isEmpty ? 'image' : alt}](${_absolute(src, base)})';
    },
  );

  text = decodeEntities(text.replaceAll(RegExp(r'<[^>]+>'), ''));

  final lines = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\r\f]+'), ' ').trimRight())
      .toList();
  var out = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  out = out.replaceAllMapped(
    RegExp(r'\u0000(\d+)\u0000'),
    (match) => blocks[int.parse(match.group(1)!)],
  );
  return out.trim();
}

/// An address the page linked to, made absolute so the model can cite it.
String _absolute(String value, Uri base) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final resolved = Uri.tryParse(raw);
  if (resolved == null) return raw;
  if (resolved.hasScheme) return resolved.toString();
  return base.resolveUri(resolved).toString();
}

String _attribute(String tag, String name) {
  final match = RegExp(
    "${RegExp.escape(name)}\\s*=\\s*[\"']([^\"']*)[\"']",
    caseSensitive: false,
  ).firstMatch(tag);
  return match?.group(1) ?? '';
}

/// The handful of entities a page uses for punctuation. Nothing here guesses at
/// markup: an unknown entity stays as written, because inventing a character
/// is worse than passing the raw one through.
String decodeEntities(String text) {
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&#x27;': "'",
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&lsquo;': '‘',
    '&rsquo;': '’',
    '&ldquo;': '“',
    '&rdquo;': '”',
  };
  var result = text;
  entities.forEach((from, to) => result = result.replaceAll(from, to));
  return result.replaceAllMapped(
    RegExp(r'&#(x?)([0-9a-fA-F]+);'),
    (match) {
      final hex = (match.group(1) ?? '').isNotEmpty;
      final code = int.tryParse(match.group(2) ?? '', radix: hex ? 16 : 10);
      if (code == null || code <= 0 || code > 0x10FFFF) return match.group(0)!;
      return String.fromCharCode(code);
    },
  );
}
