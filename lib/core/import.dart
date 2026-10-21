import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A document the user brought into a turn. Only text is kept: the bytes stay
/// where they were picked and the model reads the text as part of the message.
class ImportedDocument {
  const ImportedDocument({required this.name, required this.text});

  final String name;
  final String text;
}

/// Reading what the user picked. Images are handled by the caller (they become
/// references); this covers plain text and the three OOXML formats.
abstract final class DocumentImport {
  /// A turn should stay readable: a handful of files, each short enough to fit
  /// a small context, and a total that still leaves room for the conversation.
  static const maxFiles = 6;
  static const maxBytes = 4 << 20;
  static const maxCharacters = 20000;
  static const totalCharacters = 60000;

  static const imageExtensions = {'png', 'jpg', 'jpeg', 'webp'};

  static const textExtensions = {
    'txt', 'md', 'markdown', 'rst', 'log', 'csv', 'tsv', 'json', 'jsonl', //
    'toml', 'yaml', 'yml', 'ini', 'conf', 'properties', 'xml', 'html', 'htm',
    'css', 'dart', 'js', 'jsx', 'ts', 'tsx', 'py', 'java', 'kt', 'kts',
    'swift', 'go', 'rs', 'c', 'h', 'cc', 'cpp', 'hpp', 'cs', 'rb', 'php',
    'sh', 'bash', 'zsh', 'bat', 'ps1', 'sql', 'tex', 'srt', 'vtt',
  };

  static const officeExtensions = {'docx', 'pptx', 'xlsx'};

  /// The picker's filter. Android maps extensions to MIME types, so the common
  /// text and OOXML types are named explicitly as well.
  static const pickerExtensions = [
    ...imageExtensions,
    ...textExtensions,
    ...officeExtensions,
  ];

  static String extensionOf(String name) {
    final base = baseName(name);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? '' : base.substring(dot + 1).toLowerCase();
  }

  static bool isImage(String name) =>
      imageExtensions.contains(extensionOf(name));

  static bool isDocument(String name) {
    final extension = extensionOf(name);
    return textExtensions.contains(extension) ||
        officeExtensions.contains(extension);
  }

  /// The file name without its directory. The path is not shown to the model
  /// and may contain the user's own folder names.
  static String baseName(String name) {
    final parts = name.split(RegExp(r'[\\/]'));
    final base = parts.isEmpty ? name : parts.last;
    return sanitize(base);
  }

  /// XML-like tags carry the name, so it cannot end the tag early.
  static String sanitize(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .replaceAll('"', "'")
        .replaceAll('<', '(')
        .replaceAll('>', ')')
        .trim();
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  /// Reads one file into text. Throws `FormatException('documentEmpty')` when
  /// nothing readable is left, and `unsupportedFile` for an unknown format.
  static ImportedDocument read(String path, Uint8List bytes) {
    final name = baseName(path);
    final extension = extensionOf(name);
    final text = switch (extension) {
      'docx' => _docx(bytes),
      'pptx' => _pptx(bytes),
      'xlsx' => _xlsx(bytes),
      _ when textExtensions.contains(extension) => _plain(bytes),
      _ => throw const FormatException('unsupportedFile'),
    };
    final cleaned = _clean(text);
    if (cleaned.isEmpty) throw const FormatException('documentEmpty');
    return ImportedDocument(
      name: name,
      text: cleaned.length <= maxCharacters
          ? cleaned
          : '${cleaned.substring(0, maxCharacters)}\n…',
    );
  }

  /// The user's words first, then each file in a tag the model can recognise.
  static String compose(String prompt, List<ImportedDocument> documents) {
    final buffer = StringBuffer(prompt.trim());
    for (final document in documents) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer
        ..write('<file name="${document.name}">\n')
        ..write(document.text.trim())
        ..write('\n</file>');
    }
    return buffer.toString();
  }

  static String _clean(String text) {
    final normalised = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final stripped = normalised.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
      '',
    );
    // Word and Excel leave long runs of empty cells and paragraphs behind.
    return stripped.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static String _plain(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes, Endian.little);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes, Endian.big);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }

  /// Windows still writes UTF-16 text files, usually with a BOM.
  static String _utf16(Uint8List bytes, Endian endian) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(
        endian == Endian.little
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(units);
  }

  /// Text inside one paragraph, in document order. A run carries text, while a
  /// break or a tab sits between runs; extracting runs alone would drop them.
  static String _paragraph(String xml, String run) {
    final pattern = RegExp(
      '<$run[^>]*>(.*?)</$run>|<w:br[^>]*/>|<w:tab/>|<a:br[^>]*/>',
      dotAll: true,
    );
    final buffer = StringBuffer();
    for (final match in pattern.allMatches(xml)) {
      final text = match.group(1);
      if (text != null) {
        buffer.write(unescape(text));
      } else if (match.group(0)!.startsWith('<w:tab')) {
        buffer.write('\t');
      } else {
        buffer.write('\n');
      }
    }
    return buffer.toString();
  }

  static String _docx(Uint8List bytes) {
    final files = unzip(bytes);
    final xml = _xmlOf(files['word/document.xml']);
    final buffer = StringBuffer();
    for (final paragraph in xml.split('</w:p>')) {
      buffer.writeln(_paragraph(paragraph, 'w:t'));
    }
    return buffer.toString();
  }

  static String _pptx(Uint8List bytes) {
    final files = unzip(bytes);
    final slides =
        files.keys
            .where((key) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(key))
            .toList()
          ..sort((a, b) => _number(a).compareTo(_number(b)));
    final buffer = StringBuffer();
    for (final key in slides) {
      buffer.writeln('[slide ${_number(key)}]');
      final xml = _xmlOf(files[key]);
      for (final paragraph in xml.split('</a:p>')) {
        final text = _paragraph(paragraph, 'a:t');
        if (text.trim().isNotEmpty) buffer.writeln(text);
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _xlsx(Uint8List bytes) {
    final files = unzip(bytes);
    final shared = <String>[];
    final sharedXml = files['xl/sharedStrings.xml'];
    if (sharedXml != null) {
      for (final item in _xmlOf(sharedXml).split('</si>')) {
        shared.add(_runs(item, 't').join());
      }
    }
    final sheets =
        files.keys
            .where(
              (key) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(key),
            )
            .toList()
          ..sort((a, b) => _number(a).compareTo(_number(b)));
    final buffer = StringBuffer();
    for (final key in sheets) {
      buffer.writeln('[sheet ${_number(key)}]');
      final xml = _xmlOf(files[key]);
      final cells = RegExp(
        r'<c\b([^>]*?)(?:/>|>(.*?)</c>)',
        dotAll: true,
      );
      for (final row in xml.split('</row>')) {
        final values = <String>[];
        for (final cell in cells.allMatches(row)) {
          final attributes = cell.group(1) ?? '';
          final body = cell.group(2) ?? '';
          final type = RegExp(
            r'\bt="([^"]+)"',
          ).firstMatch(attributes)?.group(1);
          final raw = _first(
            RegExp(r'<v>(.*?)</v>', dotAll: true).allMatches(body),
          );
          if (type == 's') {
            final index = int.tryParse(unescape(raw));
            values.add(
              index != null && index >= 0 && index < shared.length
                  ? shared[index]
                  : '',
            );
          } else if (type == 'inlineStr') {
            values.add(_runs(body, 't').join());
          } else {
            values.add(unescape(raw));
          }
        }
        if (values.any((value) => value.trim().isNotEmpty)) {
          buffer.writeln(values.join('\t'));
        }
      }
    }
    return buffer.toString();
  }

  /// Text inside `name` elements. Runs are concatenated without a separator:
  /// Office splits a sentence across runs wherever formatting changes.
  static List<String> _runs(String xml, String name) => RegExp(
    '<$name(?:\\s[^>]*)?>(.*?)</$name>',
    dotAll: true,
  ).allMatches(xml).map((match) => unescape(match.group(1) ?? '')).toList();

  static String unescape(String value) => value.replaceAllMapped(
    RegExp(r'&(?:#x([0-9a-fA-F]+)|#(\d+)|(lt|gt|amp|quot|apos));'),
    (match) {
      final named = match.group(3);
      if (named != null) {
        return const {
          'lt': '<',
          'gt': '>',
          'amp': '&',
          'quot': '"',
          'apos': "'",
        }[named]!;
      }
      final hex = match.group(1);
      final code = hex != null
          ? int.parse(hex, radix: 16)
          : int.parse(match.group(2)!);
      return String.fromCharCode(code);
    },
  );

  static String _xmlOf(Uint8List? bytes) =>
      bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);

  static String _first(Iterable<RegExpMatch> matches) =>
      matches.isEmpty ? '' : matches.first.group(1) ?? '';

  static int _number(String key) =>
      int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(key)?.group(1) ?? '') ?? 0;

  /// OOXML is a zip. Stored and deflated entries are all Word, Excel and
  /// PowerPoint write, and `ZLibDecoder(raw: true)` is in `dart:io`, so the
  /// reader needs no extra package (the writer in `pptx.dart` is hand-rolled
  /// for the same reason).
  static Map<String, Uint8List> unzip(Uint8List bytes) {
    if (bytes.length < 22) throw const FormatException('unsupportedFile');
    final data = ByteData.sublistView(bytes);
    var directory = -1;
    for (var i = bytes.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50) {
        directory = i;
        break;
      }
    }
    if (directory < 0) throw const FormatException('unsupportedFile');
    final count = data.getUint16(directory + 10, Endian.little);
    var offset = data.getUint32(directory + 16, Endian.little);
    final files = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      if (offset + 46 > bytes.length ||
          data.getUint32(offset, Endian.little) != 0x02014b50) {
        throw const FormatException('unsupportedFile');
      }
      final method = data.getUint16(offset + 10, Endian.little);
      final compressed = data.getUint32(offset + 20, Endian.little);
      final nameLength = data.getUint16(offset + 28, Endian.little);
      final extraLength = data.getUint16(offset + 30, Endian.little);
      final commentLength = data.getUint16(offset + 32, Endian.little);
      final local = data.getUint32(offset + 42, Endian.little);
      if (offset + 46 + nameLength > bytes.length ||
          local + 30 > bytes.length ||
          data.getUint32(local, Endian.little) != 0x04034b50) {
        throw const FormatException('unsupportedFile');
      }
      final name = utf8.decode(
        Uint8List.sublistView(bytes, offset + 46, offset + 46 + nameLength),
        allowMalformed: true,
      );
      final localName = data.getUint16(local + 26, Endian.little);
      final localExtra = data.getUint16(local + 28, Endian.little);
      final start = local + 30 + localName + localExtra;
      if (start + compressed > bytes.length) {
        throw const FormatException('unsupportedFile');
      }
      final raw = Uint8List.sublistView(bytes, start, start + compressed);
      if (method == 0) {
        files[name] = Uint8List.fromList(raw);
      } else if (method == 8) {
        files[name] = Uint8List.fromList(
          ZLibDecoder(raw: true).convert(raw),
        );
      }
      offset += 46 + nameLength + extraLength + commentLength;
    }
    return files;
  }
}
