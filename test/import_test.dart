import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/import.dart';

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

void _u16(BytesBuilder out, int value) =>
    out.add([value & 0xFF, (value >> 8) & 0xFF]);

void _u32(BytesBuilder out, int value) => out.add([
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
]);

/// A small zip writer, so the reader is tested against a real central
/// directory instead of a hand-shaped byte array.
Uint8List _zip(Map<String, List<int>> entries, {bool deflate = false}) {
  final local = BytesBuilder();
  final central = BytesBuilder();
  final offsets = <String, int>{};
  for (final entry in entries.entries) {
    final name = utf8.encode(entry.key);
    final raw = entry.value;
    final body = deflate
        ? ZLibEncoder(raw: true).convert(raw)
        : Uint8List.fromList(raw);
    offsets[entry.key] = local.length;
    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, 0);
    _u16(local, deflate ? 8 : 0);
    _u16(local, 0);
    _u16(local, 0);
    _u32(local, _crc32(raw));
    _u32(local, body.length);
    _u32(local, raw.length);
    _u16(local, name.length);
    _u16(local, 0);
    local.add(name);
    local.add(body);
  }
  for (final entry in entries.entries) {
    final name = utf8.encode(entry.key);
    final raw = entry.value;
    final size = deflate
        ? ZLibEncoder(raw: true).convert(raw).length
        : raw.length;
    _u32(central, 0x02014b50);
    _u16(central, 20);
    _u16(central, 20);
    _u16(central, 0);
    _u16(central, deflate ? 8 : 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, _crc32(raw));
    _u32(central, size);
    _u32(central, raw.length);
    _u16(central, name.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, offsets[entry.key]!);
    central.add(name);
  }
  final directory = central.toBytes();
  final out = BytesBuilder()
    ..add(local.toBytes())
    ..add(directory);
  _u32(out, 0x06054b50);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, entries.length);
  _u16(out, entries.length);
  _u32(out, directory.length);
  _u32(out, local.length);
  _u16(out, 0);
  return out.toBytes();
}

void main() {
  test('plain text loses its BOM and normalises line endings', () {
    final bytes = Uint8List.fromList([
      0xEF, 0xBB, 0xBF, //
      ...utf8.encode('季度目标\r\n收入增长\r\n'),
    ]);
    final document = DocumentImport.read('notes.txt', bytes);
    expect(document.name, 'notes.txt');
    expect(document.text, '季度目标\n收入增长');
  });

  test('a UTF-16 text file is read through its byte order mark', () {
    final bytes = Uint8List.fromList([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00]);
    expect(DocumentImport.read('win.txt', bytes).text, 'AB');
  });

  test('a docx keeps paragraphs, runs and entities', () {
    final bytes = _zip({
      'word/document.xml': utf8.encode(
        '<w:document><w:body>'
        '<w:p><w:r><w:t>季度报告</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> 2026</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>研发 &amp; 设计</w:t></w:r>'
        '<w:r><w:br/><w:t>第二行</w:t></w:r></w:p>'
        '</w:body></w:document>',
      ),
    }, deflate: true);
    final document = DocumentImport.read('report.docx', bytes);
    expect(document.text, contains('季度报告 2026'));
    expect(document.text, contains('研发 & 设计\n第二行'));
  });

  test('a pptx lists slides in numeric order, not filename order', () {
    String slide(String text) =>
        '<p:sld><p:cSld><p:spTree><p:sp><p:txBody>'
        '<a:p><a:r><a:t>$text</a:t></a:r></a:p>'
        '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
    final bytes = _zip({
      'ppt/slides/slide10.xml': utf8.encode(slide('第十页')),
      'ppt/slides/slide2.xml': utf8.encode(slide('第二页')),
      'ppt/slides/_rels/slide2.xml.rels': utf8.encode('<Relationships/>'),
    }, deflate: true);
    final text = DocumentImport.read('deck.pptx', bytes).text;
    expect(text.indexOf('第二页'), lessThan(text.indexOf('第十页')));
    expect(text, contains('[slide 2]'));
    expect(text, contains('[slide 10]'));
  });

  test('an xlsx resolves shared strings and keeps rows apart', () {
    final bytes = _zip({
      'xl/sharedStrings.xml': utf8.encode(
        '<sst><si><t>名称</t></si>'
        '<si><r><t>数</t></r><r><t>量</t></r></si></sst>',
      ),
      'xl/worksheets/sheet1.xml': utf8.encode(
        '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="s"><v>0</v></c>'
        '<c r="B1" t="s"><v>1</v></c></row>'
        '<row r="2"><c r="A2" t="inlineStr"><is><t>苹果</t></is></c>'
        '<c r="B2"><v>42</v></c></row>'
        '<row r="3"><c r="A3"/></row>'
        '</sheetData></worksheet>',
      ),
    }, deflate: true);
    final text = DocumentImport.read('book.xlsx', bytes).text;
    expect(text, contains('[sheet 1]'));
    expect(text, contains('名称\t数量'));
    expect(text, contains('苹果\t42'));
  });

  test('a long document is cut at the character budget', () {
    final bytes = Uint8List.fromList(utf8.encode('字' * 25000));
    final text = DocumentImport.read('long.txt', bytes).text;
    expect(text.length, DocumentImport.maxCharacters + 2);
    expect(text.endsWith('…'), isTrue);
  });

  test('an empty or unknown file is refused with a code', () {
    expect(
      () => DocumentImport.read('blank.txt', Uint8List.fromList([32, 10])),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'documentEmpty',
        ),
      ),
    );
    expect(
      () => DocumentImport.read('photo.png', Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'unsupportedFile',
        ),
      ),
    );
    expect(
      () => DocumentImport.read(
        'broken.docx',
        Uint8List.fromList(utf8.encode('not a zip at all')),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'unsupportedFile',
        ),
      ),
    );
  });

  test('the message carries the prompt first and each file in a tag', () {
    final composed = DocumentImport.compose('做一份季度汇报', const [
      ImportedDocument(name: 'a.txt', text: '第一份'),
      ImportedDocument(name: 'b.json', text: '{"k":1}'),
    ]);
    expect(
      composed,
      '做一份季度汇报\n\n'
      '<file name="a.txt">\n第一份\n</file>\n\n'
      '<file name="b.json">\n{"k":1}\n</file>',
    );
    expect(
      DocumentImport.compose('', const [
        ImportedDocument(name: 'only.txt', text: '内容'),
      ]),
      '<file name="only.txt">\n内容\n</file>',
    );
  });

  test('names are reduced to a safe basename', () {
    expect(DocumentImport.baseName('/storage/emulated/0/a/b.md'), 'b.md');
    expect(DocumentImport.baseName('C:\\docs\\re"port.txt'), "re'port.txt");
    expect(DocumentImport.extensionOf('REPORT.DOCX'), 'docx');
    expect(DocumentImport.isDocument('notes.toml'), isTrue);
    expect(DocumentImport.isDocument('archive.zip'), isFalse);
    expect(DocumentImport.isImage('shot.JPEG'), isTrue);
  });
}
