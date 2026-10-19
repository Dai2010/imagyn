import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

void main() {
  test('old slides keep their JSON shape and tables round trip', () {
    const old = {
      'title': 'Title',
      'bullets': ['Point'],
      'imageId': 'image',
    };
    final plain = Slide.fromJson(old);
    expect(plain.table, isNull);
    expect(plain.toJson(), old);

    final slide = Slide(
      title: '比较',
      bullets: const ['保留要点'],
      imageId: 'image',
      table: SlideTable(
        rows: [
          ['产品', '价格'],
          ['甲', '9.9'],
        ],
        headerRow: false,
      ),
    );
    final copy = Slide.fromJson(
      jsonDecode(jsonEncode(slide.toJson())) as Map<String, dynamic>,
    );
    expect(copy.toJson(), slide.toJson());
    expect(copy.table!.headerRow, isFalse);
    expect(copy.table!.columnCount, 2);
  });

  test('table deeply copies and protects the validated row structure', () {
    final rows = [
      ['before'],
    ];
    final table = SlideTable(rows: rows);
    rows.first[0] = 'after';
    rows.add(['another']);
    expect(table.rows, [
      ['before'],
    ]);
    expect(() => table.rows.add(['x']), throwsUnsupportedError);
    expect(() => table.rows.first[0] = 'x', throwsUnsupportedError);
  });

  test('single empty cell and maximum supported dimensions are accepted', () {
    expect(
      SlideTable(
        rows: [
          [''],
        ],
      ).headerRow,
      isTrue,
    );
    final table = SlideTable(
      rows: List.generate(
        SlideTable.maxRows,
        (_) =>
            List.filled(SlideTable.maxColumns, '中' * SlideTable.maxCellLength),
      ),
    );
    expect(table.rows, hasLength(SlideTable.maxRows));
    expect(table.columnCount, SlideTable.maxColumns);
  });

  test('invalid table JSON consistently reports a format error', () {
    final invalidRows = <Object?>[
      null,
      'text',
      [],
      [[]],
      [
        ['a'],
        ['b', 'c'],
      ],
      [
        [1],
      ],
      [null],
      List.generate(SlideTable.maxRows + 1, (_) => ['a']),
      [List.filled(SlideTable.maxColumns + 1, 'a')],
      [
        ['a' * (SlideTable.maxCellLength + 1)],
      ],
    ];
    for (final rows in invalidRows) {
      expect(
        () => SlideTable.fromJson({'rows': rows}),
        throwsFormatException,
        reason: '$rows',
      );
    }
    expect(
      () => SlideTable.fromJson({
        'rows': [
          ['a'],
        ],
        'headerRow': 'yes',
      }),
      throwsFormatException,
    );
  });

  test('direct construction validates ragged and oversized input too', () {
    for (final rows in <List<List<String>>>[
      [],
      [[]],
      [
        ['a'],
        ['b', 'c'],
      ],
      List.generate(SlideTable.maxRows + 1, (_) => ['a']),
      [List.filled(SlideTable.maxColumns + 1, 'a')],
      [
        ['a' * (SlideTable.maxCellLength + 1)],
      ],
    ]) {
      expect(() => SlideTable(rows: rows), throwsFormatException);
    }
  });

  test('the shipped deck prompt upgrades while user instructions are kept', () {
    expect(
      AgentOptions.fromJson({'systemPrompt': deckAgentPrompt}).systemPrompt,
      defaultAgentPrompt,
    );
    expect(builtInAgentPrompt, contains('add_table'));
    expect(
      AgentOptions.fromJson({'systemPrompt': 'Custom'}).systemPrompt,
      'Custom',
    );
  });
}
