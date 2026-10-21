import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';

import 'support/pptx_archive.dart';

Slide _slide({List<SlideTable> tables = const [], String notes = ''}) =>
    Slide(
      title: '页面',
      bullets: const ['一级', '二级', '细节'],
      bulletLevels: const [0, 1, 2],
      notes: notes,
      tables: tables,
    );

void main() {
  test('a slide keeps two tables, notes and levels through JSON', () {
    final slide = _slide(
      tables: [
        SlideTable(rows: const [
          ['A', 'B'],
          ['1', '2'],
        ]),
        SlideTable(
          rows: const [
            ['C'],
            ['3'],
          ],
          headerRow: false,
        ),
      ],
      notes: '讲稿第一段\n讲稿第二段',
    );
    final restored = Slide.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(slide.toJson())) as Map),
    );
    expect(restored.allTables, hasLength(2));
    expect(restored.allTables.last.headerRow, isFalse);
    expect(restored.notes, '讲稿第一段\n讲稿第二段');
    expect(restored.bulletLevels, [0, 1, 2]);
  });

  test('a deck saved with one table still loads it', () {
    final restored = Slide.fromJson({
      'title': '旧页面',
      'bullets': <String>[],
      'table': {
        'rows': [
          ['甲', '乙'],
        ],
        'headerRow': true,
      },
    });
    expect(restored.allTables, hasLength(1));
    expect(restored.allTables.single.rows.single, ['甲', '乙']);
  });

  test('two tables are exported as two native tables, stacked', () {
    final deck = Deck(
      id: 'deck',
      title: '多表',
      slides: [
        _slide(
          tables: [
            SlideTable(rows: const [
              ['第一张'],
              ['内容'],
            ]),
            SlideTable(rows: const [
              ['第二张'],
              ['内容'],
            ]),
          ],
        ),
      ],
    );
    final files = unzipPptx(buildPptx(deck, {}));
    final slide = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect('<a:tbl>'.allMatches(slide), hasLength(2));
    expect(slide, contains('第一张'));
    expect(slide, contains('第二张'));
    // The second table starts below the first one.
    final first = slide.indexOf('<a:off', slide.indexOf('<a:tbl>'));
    final second = slide.indexOf('<a:tbl>', slide.indexOf('</a:tbl>'));
    expect(second, greaterThan(first));
  });

  test('bullet levels become DrawingML indent levels', () {
    final deck = Deck(id: 'deck', title: '层级', slides: [_slide()]);
    final files = unzipPptx(buildPptx(deck, {}));
    final slide = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect(slide, contains('marL="342900" indent="-342900" lvl="0"'));
    expect(slide, contains('marL="685800" indent="-342900" lvl="1"'));
    expect(slide, contains('marL="1028700" indent="-342900" lvl="2"'));
  });

  test('speaker notes get their own part and relationship', () {
    final deck = Deck(
      id: 'deck',
      title: '备注',
      slides: [
        _slide(notes: '先讲目标\n再讲数字'),
        const Slide(title: '无备注'),
      ],
    );
    final files = unzipPptx(buildPptx(deck, {}));
    final notes = utf8.decode(files['ppt/notesSlides/notesSlide1.xml']!);
    expect(notes, contains('<a:t>先讲目标</a:t>'));
    expect(notes, contains('<a:t>再讲数字</a:t>'));
    expect(files.containsKey('ppt/notesSlides/notesSlide2.xml'), isFalse);

    final types = utf8.decode(files['[Content_Types].xml']!);
    expect(types, contains('/ppt/notesMasters/notesMaster1.xml'));
    expect(types, contains('/ppt/notesSlides/notesSlide1.xml'));

    final rels = utf8.decode(files['ppt/slides/_rels/slide1.xml.rels']!);
    expect(rels, contains('relationships/notesSlide'));
    expect(
      files.containsKey('ppt/notesMasters/notesMaster1.xml'),
      isTrue,
    );
    final presentation = utf8.decode(files['ppt/presentation.xml']!);
    expect(presentation, contains('<p:notesMasterIdLst>'));
  });

  test('a designed text box exports gradient, shadow, tilt and tracking', () {
    final deck = Deck(
      id: 'deck',
      title: '艺术字',
      slides: [
        Slide(
          elements: [
            SlideElement(
              id: 'e1',
              kind: SlideElementKind.text,
              text: '开幕',
              x: .2,
              y: .3,
              width: .5,
              height: .2,
              fontSize: 48,
              fill: '7863C7',
              fill2: '4C9A8F',
              shadow: true,
              rotation: 15,
              letterSpacing: 3,
              radius: .2,
              color: 'FFFFFF',
            ),
          ],
        ),
      ],
    );
    final files = unzipPptx(buildPptx(deck, {}));
    final slide = utf8.decode(files['ppt/slides/slide1.xml']!);
    expect(slide, contains('<a:gradFill'));
    expect(slide, contains('<a:gs pos="0"><a:srgbClr val="7863C7"/>'));
    expect(slide, contains('<a:gs pos="100000"><a:srgbClr val="4C9A8F"/>'));
    expect(slide, contains('<a:outerShdw'));
    expect(slide, contains('rot="900000"'));
    expect(slide, contains('spc="300"'));
  });

  test('an unusable tilt or tracking is refused', () {
    SlideElement build({double rotation = 0, double letterSpacing = 0}) =>
        SlideElement(
          id: 'e1',
          kind: SlideElementKind.text,
          text: '标签',
          x: .1,
          y: .1,
          width: .3,
          height: .1,
          fontSize: 18,
          rotation: rotation,
          letterSpacing: letterSpacing,
        );
    expect(() => build(rotation: 46), throwsFormatException);
    expect(() => build(letterSpacing: 21), throwsFormatException);
    expect(build(rotation: -45, letterSpacing: -2).rotation, -45);
  });

  test('the new tools are offered to the model', () {
    expect(
      agentTools.map((tool) => tool['name']),
      containsAll(['set_notes']),
    );
    final addTable = agentTools.firstWhere(
      (tool) => tool['name'] == 'add_table',
    );
    expect(
      ((addTable['parameters'] as Map)['required'] as List),
      contains('table_index'),
    );
  });
}
