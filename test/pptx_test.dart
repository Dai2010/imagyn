import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';

final _crcTable = List<int>.generate(256, (n) {
  var value = n;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// Reads the stored archive back the way a package reader would: through the
/// central directory, checking each entry's CRC instead of trusting the bytes.
Map<String, Uint8List> _unzip(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  expect(eocd, isNonNegative, reason: 'end of central directory');
  final count = data.getUint16(eocd + 10, Endian.little);
  var offset = data.getUint32(eocd + 16, Endian.little);
  final files = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    expect(data.getUint32(offset, Endian.little), 0x02014b50);
    expect(data.getUint16(offset + 10, Endian.little), 0, reason: 'stored');
    final crc = data.getUint32(offset + 16, Endian.little);
    final size = data.getUint32(offset + 20, Endian.little);
    final nameLength = data.getUint16(offset + 28, Endian.little);
    final extraLength = data.getUint16(offset + 30, Endian.little);
    final commentLength = data.getUint16(offset + 32, Endian.little);
    final local = data.getUint32(offset + 42, Endian.little);
    final name = utf8.decode(
      Uint8List.sublistView(bytes, offset + 46, offset + 46 + nameLength),
    );
    expect(data.getUint32(local, Endian.little), 0x04034b50);
    final localName = data.getUint16(local + 26, Endian.little);
    final localExtra = data.getUint16(local + 28, Endian.little);
    final start = local + 30 + localName + localExtra;
    final content = Uint8List.sublistView(bytes, start, start + size);
    expect(_crc32(content), crc, reason: name);
    files[name] = content;
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return files;
}

void main() {
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0, 0, 0, 13, 73, 72, 68, 82,
  ]);

  test('writes one editable slide per page with pictures', () {
    final deck = Deck(
      id: 'deck',
      title: 'R&D <2026>',
      slides: const [
        Slide(
          title: 'R&D <2026>',
          bullets: ['第一点', 'Second & point'],
          imageId: 'img-1',
        ),
        Slide(title: '结尾', imageId: 'img-1'),
      ],
    );
    final files = _unzip(
      buildPptx(deck, {
        'img-1': PptxImage(
          bytes: png,
          mime: 'image/png',
          width: 1600,
          height: 900,
        ),
      }),
    );

    expect(files.keys, containsAll([
      '[Content_Types].xml',
      '_rels/.rels',
      'ppt/presentation.xml',
      'ppt/_rels/presentation.xml.rels',
      'ppt/slideMasters/slideMaster1.xml',
      'ppt/slideMasters/_rels/slideMaster1.xml.rels',
      'ppt/slideLayouts/slideLayout1.xml',
      'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      'ppt/theme/theme1.xml',
      'ppt/slides/slide1.xml',
      'ppt/slides/slide2.xml',
      'ppt/slides/_rels/slide1.xml.rels',
      'ppt/slides/_rels/slide2.xml.rels',
      'ppt/media/image1.png',
    ]));

    final slide1 = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect(slide1, contains('<a:t>R&amp;D &lt;2026&gt;</a:t>'));
    expect(slide1, contains('<a:t>第一点</a:t>'));
    expect(slide1, contains('<a:t>Second &amp; point</a:t>'));
    expect(slide1, contains('<p:pic>'));
    expect(slide1, contains('r:embed="rId2"'));
    expect(slide1, contains('<a:ea typeface="Microsoft YaHei"/>'));
    expect(slide1, contains('<a:latin typeface="Aptos"/>'));
    expect(slide1, isNot(contains('R&D <2026>')));

    final slide2 = utf8.decode(files['ppt/slides/slide2.xml']!);
    expect(slide2, contains('<a:t>结尾</a:t>'));
    expect(slide2, contains('r:embed="rId2"'));

    final presentation = utf8.decode(files['ppt/presentation.xml']!);
    expect(presentation, contains('<p:sldSz cx="12192000" cy="6858000"/>'));
    expect(presentation, contains('r:id="rId3"'));
    expect(presentation, contains('r:id="rId4"'));

    final types = utf8.decode(files['[Content_Types].xml']!);
    expect(types, startsWith('<?xml'));
    expect(types, endsWith('</Types>'));
    expect(types, contains('PartName="/ppt/slides/slide1.xml"'));
    expect(types, contains('PartName="/ppt/slides/slide2.xml"'));
    expect(types, contains('Extension="png" ContentType="image/png"'));

    final rootRels = utf8.decode(files['_rels/.rels']!);
    expect(rootRels, contains('relationships/officeDocument'));
    expect(rootRels, contains('Target="ppt/presentation.xml"'));

    expect(files['ppt/media/image1.png'], png);
    expect(
      files.keys.where((name) => name.startsWith('ppt/media/')),
      hasLength(1),
      reason: 'one picture shared by two slides is stored once',
    );
  });

  test('4:3 decks use the 4:3 slide size', () {
    final deck = Deck(
      id: 'deck',
      title: '测试',
      aspectRatio: '4:3',
      slides: const [Slide(title: '第一页')],
    );
    final presentation = utf8.decode(
      _unzip(buildPptx(deck, {}))['ppt/presentation.xml']!,
    );
    expect(presentation, contains('cx="9144000"'));
    expect(presentation, contains('cy="6858000"'));
  });

  test('a deck with no slides is still a readable package', () {
    final files = _unzip(buildPptx(Deck(id: 'deck', title: '空'), {}));
    final presentation = utf8.decode(files['ppt/presentation.xml']!);
    expect(presentation, isNot(contains('<p:sldIdLst>')));
    expect(
      files.keys.where((name) => name.startsWith('ppt/slides/')),
      isEmpty,
    );
    expect(
      utf8.decode(files['[Content_Types].xml']!),
      isNot(contains('Extension="png"')),
    );
  });

  test('a WebP picture keeps its own media extension', () {
    final webp = Uint8List.fromList([0x52, 0x49, 0x46, 0x46]);
    final deck = Deck(
      id: 'deck',
      title: '测试',
      slides: const [Slide(title: '第一页', imageId: 'webp-1')],
    );
    final files = _unzip(
      buildPptx(deck, {
        'webp-1': PptxImage(
          bytes: webp,
          mime: 'image/webp',
          width: 64,
          height: 64,
        ),
      }),
    );
    expect(files.keys, contains('ppt/media/image1.webp'));
    expect(
      utf8.decode(files['[Content_Types].xml']!),
      contains('Extension="webp" ContentType="image/webp"'),
    );
  });
}
