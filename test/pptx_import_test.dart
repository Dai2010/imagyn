import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';
import 'package:imagyn/core/pptx_import.dart';

void main() {
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0, 0, 0, 13, 73, 72, 68, 82,
  ]);

  test('an exported deck comes back as editable content', () {
    final deck = Deck(
      id: 'deck',
      title: '往返',
      backgroundColor: null,
      slides: [
        Slide(
          backgroundColor: '112233',
          notes: '先讲目标\n再讲数字',
          tables: [
            SlideTable(rows: const [
              ['指标', '值'],
              ['收入', '42'],
            ]),
          ],
          elements: [
            SlideElement(
              id: 'e1',
              kind: SlideElementKind.text,
              text: '卡片文字',
              x: .1,
              y: .1,
              width: .5,
              height: .2,
              fontSize: 30,
              color: 'FFFFFF',
            ),
            SlideElement(
              id: 'e2',
              kind: SlideElementKind.image,
              imageId: 'img',
              x: .6,
              y: .5,
              width: .3,
              height: .3,
            ),
          ],
        ),
        Slide(
          title: '第二页',
          bullets: const ['一级', '二级'],
          bulletLevels: const [0, 1],
        ),
      ],
    );
    final bytes = buildPptx(deck, {
      'img': PptxImage(bytes: png, mime: 'image/png', width: 16, height: 9),
    });
    final imported = PptxImport.read('我的演示.pptx', bytes, id: 'copy');

    expect(imported.deck.id, 'copy');
    expect(imported.deck.title, '我的演示');
    expect(imported.deck.aspectRatio, '16:9');
    expect(imported.deck.slides, hasLength(2));

    final first = imported.deck.slides.first;
    expect(first.backgroundColor, '112233');
    expect(first.notes, contains('先讲目标'));
    expect(first.notes, contains('再讲数字'));
    expect(first.allTables, hasLength(1));
    expect(first.allTables.single.rows.first, ['指标', '值']);
    expect(
      first.elements.map((element) => element.text).join(),
      contains('卡片文字'),
    );
    expect(first.elements.where((e) => e.kind == SlideElementKind.image),
        hasLength(1));
    expect(imported.media, hasLength(1));
    expect(imported.media.values.single, png);

    final second = imported.deck.slides.last;
    final text = second.elements.map((element) => element.text).join('\n');
    expect(text, contains('第二页'));
    expect(text, contains('• 一级'));
  });

  test('a file that is not a zip is refused with a code', () {
    expect(
      () => PptxImport.read(
        'broken.pptx',
        Uint8List.fromList(utf8.encode('not a deck at all')),
        id: 'x',
      ),
      throwsFormatException,
    );
  });
}
