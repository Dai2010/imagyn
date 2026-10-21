import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/pptx.dart';
import 'package:xml/xml.dart';

import 'support/deck_studio.dart';
import 'support/pptx_archive.dart';

// Real loopback protocol -> agent dispatch -> shared model -> OOXML archive.
// Kept outside widget suites because their binding intercepts HTTP sockets.
Future<DeckStudio> runTableTurn(
  List<Map<String, dynamic>> Function(String deck) calls, {
  bool grouped = true,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  var next = 0;
  final store = DeckStore()
    ..savedConfig = ServiceConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      agentModel: 'agent',
      streamAgent: false,
    );
  final studio = DeckStudio(store);
  addTearDown(studio.dispose);
  final subscription = server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    final tools = (body['tools'] as List).cast<Map>();
    expect(
      tools.any((t) => (t['function'] as Map)['name'] == 'add_table'),
      isTrue,
    );
    final script = calls(studio.activeDeck?.id ?? 'pending');
    final batch = <Map<String, dynamic>>[];
    // Establish the deck/slide first, then exercise a multi-tool response too.
    final count = !grouped || next < 2 ? 1 : 4;
    for (var i = 0; i < count && next < script.length; i++) {
      final item = script[next++];
      batch.add({
        'id': 'call-$next',
        'type': 'function',
        'function': {
          'name': item['name'],
          'arguments': jsonEncode(item['args']),
        },
      });
    }
    final message = batch.isEmpty
        ? {'content': '完成'}
        : {'content': '', 'tool_calls': batch};
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {'message': message},
        ],
      }),
    );
    await request.response.close();
  });
  addTearDown(subscription.cancel);
  await studio.initialize();
  await studio.submit('制作带可编辑表格的演示文稿', true, const ImageOptions());
  expect(studio.error, isNull);
  expect(next, calls(studio.activeDeck?.id ?? '').length);
  return studio;
}

Map<String, dynamic> call(String name, Map<String, dynamic> args) => {
  'name': name,
  'args': args,
};

List<Map<String, dynamic>> initialCalls(String deck) => [
  call('create_deck', {'title': '表格演示', 'aspect_ratio': '16:9'}),
  call('add_slide', {
    'deck': deck,
    'title': '原始标题',
    'bullets': ['要点'],
    'image_id': '',
  }),
];

void main() {
  test('four table pages finish through sequential tool requests', () async {
    final studio = await runTableTurn(
      (deck) => [
        call('create_deck', {'title': '四页表格', 'aspect_ratio': '4:3'}),
        for (var i = 0; i < 4; i++) ...[
          call('add_slide', {
            'deck': deck,
            'title': 'Page $i',
            'bullets': [],
            'image_id': '',
          }),
          call('add_table', {
            'deck': deck,
            'index': i,
            'rows': [
              ['Row $i'],
            ],
            'header_row': false,
          }),
        ],
        call('finish_deck', {'deck': deck}),
      ],
      grouped: false,
    );
    expect(studio.activeDeck!.finished, isTrue);
    expect(studio.activeDeck!.slides, hasLength(4));
    expect(studio.chat.last.text, '完成');
  });

  test(
    'a turn creates, replaces, edits and exports a native text table',
    () async {
      final studio = await runTableTurn(
        (deck) => [
          ...initialCalls(deck),
          call('add_table', {
            'deck': deck,
            'index': 0,
            'rows': [
              ['旧表'],
            ],
            'header_row': false,
          }),
          call('add_table', {
            'deck': deck,
            'index': 0,
            'rows': [
              ['列一', '列二'],
              ['A&B', '中\n文'],
            ],
            'header_row': true,
          }),
          call('update_slide', {
            'deck': deck,
            'index': 0,
            'title': '更新标题',
            'bullets': ['更新要点'],
          }),
          call('finish_deck', {'deck': deck}),
        ],
      );
      final deck = studio.activeDeck!;
      expect(deck.finished, isTrue);
      expect(deck.slides.single.title, '更新标题');
      expect(deck.slides.single.allTables.first.rows, [
        ['列一', '列二'],
        ['A&B', '中\n文'],
      ]);
      final files = unzipPptx(buildPptx(deck, {}));
      final xml = XmlDocument.parse(
        utf8.decode(files['ppt/slides/slide1.xml']!),
      );
      const drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
      final table = xml.findAllElements('tbl', namespace: drawing).single;
      final rows = table.findElements('tr', namespace: drawing).toList();
      expect(rows, hasLength(2));
      expect(rows.first.findElements('tc', namespace: drawing), hasLength(2));
      expect(
        table.findAllElements('t', namespace: drawing).map((e) => e.innerText),
        ['列一', '列二', 'A&B', '中', '文'],
      );
      expect(xml.toXmlString(), contains('更新要点'));
    },
  );

  test(
    'malformed table calls leave the previous table intact and can recover',
    () async {
      final invalid = <Map<String, dynamic>>[
        {'rows': []},
        {
          'rows': [[]],
        },
        {
          'rows': [
            ['a'],
            ['b', 'c'],
          ],
        },
        {
          'rows': [
            [1],
          ],
        },
        {'rows': 'text'},
        {
          'rows': [
            ['x'],
          ],
          'index': -1,
        },
        {
          'rows': [
            ['x'],
          ],
          'index': 1,
        },
        {
          'rows': [
            ['x'],
          ],
          'index': 0.0,
        },
        {
          'rows': [
            ['x'],
          ],
          'deck': 'missing',
        },
        {
          'rows': [
            ['x'],
          ],
          'header_row': 'true',
        },
        {
          'rows': List.generate(13, (_) => ['x']),
        },
        {
          'rows': [List.filled(9, 'x')],
        },
        {
          'rows': [
            ['x' * 501],
          ],
        },
        {
          'rows': [
            ['x'],
          ],
          'header_row': null,
        },
      ];
      final studio = await runTableTurn(
        (deck) => [
          ...initialCalls(deck),
          call('add_table', {
            'deck': deck,
            'index': 0,
            'rows': [
              ['保留'],
            ],
            'header_row': false,
          }),
          for (final args in invalid)
            call('add_table', {
              'deck': deck,
              'index': 0,
              'header_row': true,
              ...args,
            }),
          call('finish_deck', {'deck': deck}),
        ],
      );
      expect(studio.activeDeck!.slides.single.allTables.first.rows, [
        ['保留'],
      ]);
      expect(
        studio.chat.where(
          (e) =>
              e.name == 'add_table' &&
              e.role == 'tool' &&
              e.text.startsWith('Invalid arguments'),
        ),
        hasLength(invalid.length),
      );
      expect(studio.activeDeck!.finished, isTrue);
    },
  );
}
