import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';
import 'package:xml/xml.dart';

import 'support/pptx_archive.dart';

const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _p = 'http://schemas.openxmlformats.org/presentationml/2006/main';

XmlDocument _slideDocument(Map<String, Uint8List> files, [int number = 1]) =>
    XmlDocument.parse(utf8.decode(files['ppt/slides/slide$number.xml']!));

List<XmlElement> _elements(
  XmlNode node,
  String name, [
  String namespace = _a,
]) => node.findAllElements(name, namespace: namespace).toList();

/// Validate the grid against the frame instead of accepting a matching number
/// of XML tags: Office uses both sets of dimensions when editing a table.
void _expectTableDimensions(XmlDocument slide, int rows, int columns) {
  final frame = _elements(slide, 'graphicFrame', _p).single;
  final ext = _elements(frame, 'ext').single;
  final grid = _elements(frame, 'gridCol');
  final tableRows = _elements(frame, 'tr');
  expect(grid, hasLength(columns));
  expect(tableRows, hasLength(rows));
  final widths = grid.map((col) => int.parse(col.getAttribute('w')!)).toList();
  final heights = tableRows
      .map((row) => int.parse(row.getAttribute('h')!))
      .toList();
  expect(widths, everyElement(isPositive));
  expect(heights, everyElement(isPositive));
  expect(widths.reduce((a, b) => a + b), int.parse(ext.getAttribute('cx')!));
  expect(heights.reduce((a, b) => a + b), int.parse(ext.getAttribute('cy')!));
  for (final row in tableRows) {
    expect(row.findElements('tc', namespace: _a), hasLength(columns));
  }
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
    final files = unzipPptx(
      buildPptx(deck, {
        'img-1': PptxImage(
          bytes: png,
          mime: 'image/png',
          width: 1600,
          height: 900,
        ),
      }),
    );

    expect(
      files.keys,
      containsAll([
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
      ]),
    );

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
      unzipPptx(buildPptx(deck, {}))['ppt/presentation.xml']!,
    );
    expect(presentation, contains('cx="9144000"'));
    expect(presentation, contains('cy="6858000"'));
  });

  test('a deck with no slides is still a readable package', () {
    final files = unzipPptx(buildPptx(Deck(id: 'deck', title: '空'), {}));
    final presentation = utf8.decode(files['ppt/presentation.xml']!);
    expect(presentation, isNot(contains('<p:sldIdLst>')));
    expect(files.keys.where((name) => name.startsWith('ppt/slides/')), isEmpty);
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
    final files = unzipPptx(
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

  test('a background picture fills the page behind an editable scrim', () {
    final deck = Deck(
      id: 'deck',
      title: '背景',
      backgroundImageId: 'bg',
      slides: const [
        Slide(title: '共用背景', bullets: ['要点']),
        Slide(title: '单独背景', backgroundImageId: 'own'),
        Slide(title: '不要背景', backgroundImageId: ''),
      ],
    );
    final files = unzipPptx(
      buildPptx(deck, {
        'bg': PptxImage(
          bytes: png,
          mime: 'image/png',
          width: 1600,
          height: 900,
        ),
        'own': PptxImage(
          bytes: png,
          mime: 'image/png',
          width: 900,
          height: 1600,
        ),
      }),
    );

    final first = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect(first, contains('<a:blipFill dpi="0" rotWithShape="1">'));
    expect(first, contains('r:embed="rId2"'));
    expect(first, contains('name="Background scrim"'));
    expect(first, contains('<a:alpha val="52000"/>'));
    // The scrim is a shape the user can delete, not part of the picture.
    expect(first, contains('<p:pic>'), isFalse);
    final firstRels = utf8.decode(files['ppt/slides/_rels/slide1.xml.rels']!);
    expect(firstRels, contains('Target="../media/image1.png"'));

    final second = utf8.decode(files['ppt/slides/slide2.xml']!);
    expect(second, contains('r:embed="rId2"'));
    final secondRels = utf8.decode(files['ppt/slides/_rels/slide2.xml.rels']!);
    expect(secondRels, contains('Target="../media/image2.png"'));

    // An explicit empty id cancels the deck background on that page.
    final third = utf8.decode(files['ppt/slides/slide3.xml']!);
    expect(third, isNot(contains('a:blipFill')));
    expect(third, isNot(contains('Background scrim')));
    expect(third, contains('<a:srgbClr val="FBFAFE"/>'));

    expect(
      files.keys.where((name) => name.startsWith('ppt/media/')),
      hasLength(2),
      reason: 'a deck background shared by pages is stored once',
    );
  });

  test('writes a native editable table with explicit header styling', () {
    final deck = Deck(
      id: 'table',
      title: '表格',
      slides: [
        Slide(
          title: '指标',
          table: SlideTable(
            rows: [
              ['项目', 'R&D <2026>'],
              ['中文单元格', '42'],
              ['', '  两端空格  '],
            ],
          ),
        ),
      ],
    );
    final files = unzipPptx(buildPptx(deck, {}));
    // Every XML/relationship part remains independently parseable.
    for (final entry in files.entries) {
      if (entry.key.endsWith('.xml') || entry.key.endsWith('.rels')) {
        expect(
          () => XmlDocument.parse(utf8.decode(entry.value)),
          returnsNormally,
          reason: entry.key,
        );
      }
    }
    final slide = _slideDocument(files);
    final table = _elements(slide, 'tbl').single;
    final graphicData = _elements(slide, 'graphicData').single;
    expect(
      graphicData.getAttribute('uri'),
      'http://schemas.openxmlformats.org/drawingml/2006/table',
    );
    expect(table.childElements.map((child) => child.name.local), [
      'tblPr',
      'tblGrid',
      'tr',
      'tr',
      'tr',
    ]);
    expect(_elements(table, 'tblPr').single.getAttribute('firstRow'), '1');
    _expectTableDimensions(slide, 3, 2);

    final cells = _elements(table, 'tc');
    expect(cells.map((cell) => _elements(cell, 't').single.innerText), [
      '项目',
      'R&D <2026>',
      '中文单元格',
      '42',
      '',
      '  两端空格  ',
    ]);
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      expect(cell.childElements.map((child) => child.name.local), [
        'txBody',
        'tcPr',
      ]);
      expect(_elements(cell, 'normAutofit'), hasLength(1));
      expect(
        _elements(cell, 'rPr').single.getAttribute('b'),
        i < 2 ? '1' : '0',
      );
      final fill = _elements(cell, 'tcPr').single
          .findElements('solidFill', namespace: _a)
          .single
          .findElements('srgbClr', namespace: _a)
          .single;
      expect(
        fill.getAttribute('val'),
        i < 2 ? '7863C7' : (i < 4 ? 'FFFFFF' : 'F4F2FA'),
      );
    }
    expect(_elements(slide, 'pic', _p), isEmpty);
    expect(files.keys.where((name) => name.startsWith('ppt/media/')), isEmpty);
  });

  test('single cell table keeps whitespace and line breaks and cleans XML', () {
    final files = unzipPptx(
      buildPptx(
        Deck(
          id: 'edge',
          title: '单格',
          slides: [
            Slide(
              table: SlideTable(
                rows: [
                  [
                    '\n  中文 & < > " \'\t\r\n第二行\r\u0000\u0001\u000b\ufffe\uffff\n',
                  ],
                ],
              ),
            ),
          ],
        ),
        {},
      ),
    );
    final slide = _slideDocument(files);
    _expectTableDimensions(slide, 1, 1);
    final cell = _elements(slide, 'tc').single;
    expect(
      _elements(cell, 'p').map((p) => _elements(p, 't').single.innerText),
      ['', '  中文 & < > " \'\t', '第二行', '', ''],
    );
    final xml = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect(xml, contains('&amp; &lt; &gt; &quot; &apos;'));
    expect(xml, isNot(contains('\u0000')));
    expect(xml, isNot(contains('\ufffe')));
    expect(xml, isNot(contains('\uffff')));
  });

  test('headerRow false leaves every cell styled as body text', () {
    final slide = _slideDocument(
      unzipPptx(
        buildPptx(
          Deck(
            id: 'plain',
            title: '数据',
            slides: [
              Slide(
                table: SlideTable(
                  rows: [
                    ['first', 'row'],
                    ['next', 'row'],
                  ],
                  headerRow: false,
                ),
              ),
            ],
          ),
          {},
        ),
      ),
    );
    expect(_elements(slide, 'tblPr').single.getAttribute('firstRow'), '0');
    expect(
      _elements(
        _elements(slide, 'tbl').single,
        'rPr',
      ).map((run) => run.getAttribute('b')),
      everyElement('0'),
    );
    expect(
      _elements(
        _elements(slide, 'tcPr').first,
        'srgbClr',
      ).last.getAttribute('val'),
      'F4F2FA',
    );
  });

  test('excessive explicit lines fail with a useful export error', () {
    final deck = Deck(
      id: 'too-dense',
      title: '换行上限',
      slides: [
        Slide(
          table: SlideTable(
            rows: [
              [List.filled(500, '\n').join()],
            ],
          ),
        ),
      ],
    );
    expect(
      () => buildPptx(deck, {}),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'cell location',
              contains('row 1, column 1'),
            )
            .having(
              (error) => error.message,
              'actionable limit',
              contains('split the table'),
            ),
      ),
    );
  });

  test(
    'dense mixed content fits long words, CJK and emoji with valid fonts',
    () {
      final values = [
        List.filled(500, 'W').join(),
        List.filled(500, '中').join(),
        List.filled(250, '😀').join(),
      ];
      for (final value in values) {
        final files = unzipPptx(
          buildPptx(
            Deck(
              id: 'dense',
              title: '长文本',
              aspectRatio: '4:3',
              slides: [
                Slide(
                  bullets: ['表格说明'],
                  imageId: 'image',
                  table: SlideTable(
                    rows: List.generate(
                      12,
                      (row) => List.generate(
                        8,
                        (column) =>
                            row == 1 && column == 1 ? value : '$row,$column',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            {
              'image': PptxImage(
                bytes: png,
                mime: 'image/png',
                width: 1600,
                height: 900,
              ),
            },
          ),
        );
        final slide = _slideDocument(files);
        _expectTableDimensions(slide, 12, 8);
        final cell = _elements(
          slide,
          'tr',
        )[1].findElements('tc', namespace: _a).elementAt(1);
        expect(_elements(cell, 't').single.innerText, value);
        expect(
          int.parse(_elements(cell, 'rPr').single.getAttribute('sz')!),
          inInclusiveRange(100, 1800),
        );
      }
    },
  );

  test(
    'table, bullets, title and picture occupy separate editable objects',
    () {
      final files = unzipPptx(
        buildPptx(
          Deck(
            id: 'mixed',
            title: '混合',
            slides: [
              Slide(
                title: '图文表',
                bullets: ['数据说明', '第二点'],
                imageId: 'image',
                table: SlideTable(
                  rows: [
                    ['名称', '值'],
                    ['A', '12'],
                  ],
                ),
              ),
            ],
          ),
          {
            'image': PptxImage(
              bytes: png,
              mime: 'image/png',
              width: 1600,
              height: 900,
            ),
          },
        ),
      );
      final slide = _slideDocument(files);
      _expectTableDimensions(slide, 2, 2);
      expect(_elements(slide, 'pic', _p), hasLength(1));
      final shapeNames = _elements(
        slide,
        'cNvPr',
        _p,
      ).map((shape) => shape.getAttribute('name')).toList();
      expect(
        shapeNames,
        containsAll(['Title 0', 'Content 0', 'Table 0', 'Picture 0', 'Page 1']),
      );
      final ids = _elements(
        slide,
        'cNvPr',
        _p,
      ).map((shape) => shape.getAttribute('id')).toList();
      expect(ids.toSet(), hasLength(ids.length));
      final bulletShape = _elements(slide, 'sp', _p).singleWhere(
        (shape) =>
            _elements(shape, 'cNvPr', _p).single.getAttribute('name') ==
            'Content 0',
      );
      final bulletOff = _elements(bulletShape, 'off').single;
      final bulletExt = _elements(bulletShape, 'ext').single;
      final frame = _elements(slide, 'graphicFrame', _p).single;
      final tableOff = _elements(frame, 'off').single;
      final tableExt = _elements(frame, 'ext').single;
      expect(
        int.parse(tableOff.getAttribute('y')!),
        greaterThan(
          int.parse(bulletOff.getAttribute('y')!) +
              int.parse(bulletExt.getAttribute('cy')!),
        ),
      );
      expect(tableExt.getAttribute('cx'), bulletExt.getAttribute('cx'));
      final picture = _elements(slide, 'pic', _p).single;
      final pictureOff = _elements(picture, 'off').single;
      expect(
        int.parse(pictureOff.getAttribute('x')!),
        greaterThan(
          int.parse(tableOff.getAttribute('x')!) +
              int.parse(tableExt.getAttribute('cx')!),
        ),
      );
      expect(
        _elements(slide, 't').map((text) => text.innerText),
        containsAll(['图文表', '数据说明', '第二点', '名称', '值', 'A', '12', '1']),
      );
      expect(files['ppt/media/image1.png'], png);
    },
  );

  for (final ratio in ['16:9', '4:3']) {
    test('$ratio maximum size table has exact positive grid dimensions', () {
      final longCell = List.filled(500, 'x').join();
      final slide = _slideDocument(
        unzipPptx(
          buildPptx(
            Deck(
              id: 'largest',
              title: '边界',
              aspectRatio: ratio,
              slides: [
                Slide(
                  bullets: ['表格说明'],
                  table: SlideTable(
                    rows: List.generate(
                      12,
                      (row) => List.generate(
                        8,
                        (col) => row == 1 && col == 1 ? longCell : '$row,$col',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            {},
          ),
        ),
      );
      _expectTableDimensions(slide, 12, 8);
      final frame = _elements(slide, 'graphicFrame', _p).single;
      final off = _elements(frame, 'off').single;
      final ext = _elements(frame, 'ext').single;
      expect(
        int.parse(off.getAttribute('x')!) + int.parse(ext.getAttribute('cx')!),
        lessThan(ratio == '4:3' ? 9144000 : 12192000),
      );
      expect(
        int.parse(off.getAttribute('y')!) + int.parse(ext.getAttribute('cy')!),
        lessThan(6858000),
      );
      expect(_elements(slide, 'tc'), hasLength(96));
      expect(
        _elements(slide, 't').map((text) => text.innerText),
        contains(longCell),
      );
    });
  }
}
