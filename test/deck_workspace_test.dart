import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/main.dart';
import 'package:imagyn/ui/deck_workspace.dart';

import 'support/deck_studio.dart';

void main() {
  testWidgets('pages arrive and leave with an animation', (tester) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(id: 'deck', title: '测试演示');
    studio.decks[deck.id] = deck;
    studio.activeDeck = deck;

    await tester.pumpWidget(
      MaterialApp(home: DeckWorkspacePage(studio: studio, deck: deck)),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试演示'), findsOneWidget);
    expect(find.text('Planning the first slide…'), findsOneWidget);

    deck.slides.add(const Slide(title: '第一页', bullets: ['要点一', '要点二']));
    studio.notifyListeners();
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('第一页'), findsOneWidget);
    expect(find.text('Planning the first slide…'), findsNothing);

    deck.slides.add(const Slide(title: '第二页', bullets: ['另一要点']));
    studio.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('第一页'), findsOneWidget);
    expect(find.text('第二页'), findsOneWidget);

    deck.slides.removeAt(0);
    studio.notifyListeners();
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('第一页'), findsNothing);
    expect(find.text('第二页'), findsOneWidget);

    deck.finished = true;
    studio.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('Deck finished'), findsOneWidget);
  });

  testWidgets('a page opens full size and closes again', (tester) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(
      id: 'deck',
      title: '测试演示',
      slides: [const Slide(title: '第一页', bullets: ['要点'])],
    );
    studio.decks[deck.id] = deck;
    studio.activeDeck = deck;
    await tester.pumpWidget(
      MaterialApp(home: DeckWorkspacePage(studio: studio, deck: deck)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('第一页'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('第一页'), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('a page whose image is gone says so instead of failing', (
    tester,
  ) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(
      id: 'deck',
      title: '测试演示',
      slides: [const Slide(title: '配图页', imageId: 'missing')],
    );
    studio.decks[deck.id] = deck;
    studio.activeDeck = deck;
    await tester.pumpWidget(
      MaterialApp(home: DeckWorkspacePage(studio: studio, deck: deck)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tables show every cell in the thumbnail and full-size page', (
    tester,
  ) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(
      id: 'table-deck',
      title: 'Table deck',
      finished: true,
      slides: [
        Slide(
          title: 'Sales table',
          bullets: const ['Quarterly results'],
          table: SlideTable(
            rows: const [
              ['Product', 'Revenue'],
              ['A & B', '100 < 200'],
              ['Multiline\ncell', '中文'],
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DeckWorkspacePage(studio: studio, deck: deck),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(3));
    expect(table.children.every((row) => row.children.length == 2), isTrue);
    for (final row in deck.slides.single.allTables.first.rows) {
      for (final cell in row) {
        expect(find.text(cell), findsOneWidget);
      }
    }
    expect(
      tester.widget<Text>(find.text('Product')).style!.fontWeight,
      FontWeight.w600,
    );
    expect(
      tester.widget<Text>(find.text('A & B')).style!.fontWeight,
      FontWeight.w400,
    );
    expect(find.text('Quarterly results'), findsOneWidget);

    await tester.tap(find.text('Sales table'));
    await tester.pumpAndSettle();
    expect(find.byType(Table), findsNWidgets(2));
    expect(find.text('100 < 200'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('table replacement refreshes cells and the header flag', (
    tester,
  ) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(
      id: 'table-deck',
      title: 'Table deck',
      finished: true,
      slides: [
        Slide(
          title: 'Table',
          table: SlideTable(
            rows: const [
              ['Old header'],
              ['Old value'],
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DeckWorkspacePage(studio: studio, deck: deck),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Old value'), findsOneWidget);

    deck.slides[0] = Slide(
      title: 'Table',
      table: SlideTable(
        rows: const [
          ['New first', 'New second'],
        ],
        headerRow: false,
      ),
    );
    studio.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('Old value'), findsNothing);
    expect(find.text('Old header'), findsNothing);
    expect(find.text('New first'), findsOneWidget);
    expect(find.text('New second'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('New first')).style!.fontWeight,
      FontWeight.w400,
    );
    final table = tester.widget<Table>(find.byType(Table));
    final decoration = table.children.single.decoration! as BoxDecoration;
    final context = tester.element(find.byType(Table));
    expect(decoration.color, Theme.of(context).colorScheme.surfaceContainer);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one empty cell fills the body when bullets are blank', (
    tester,
  ) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(
      id: 'empty-cell',
      title: 'Empty cell deck',
      finished: true,
      slides: [
        Slide(
          title: 'Empty cell',
          bullets: const ['   ', '\n'],
          table: SlideTable(
            rows: const [
              [''],
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DeckWorkspacePage(studio: studio, deck: deck),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(1));
    expect(table.children.single.children, hasLength(1));
    expect(tester.getSize(find.byType(Table)).height, greaterThan(200));
    expect(find.text('   '), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final ratio in ['16:9', '4:3']) {
    testWidgets('dense $ratio tables and images fit a narrow phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('imagyn-table-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/image.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
      final store = _ImageDeckStore();
      store.savedAssets['image'] = Asset(
        id: 'image',
        path: file.path,
        mime: 'image/png',
        prompt: '',
        createdAt: DateTime.utc(2026),
      );
      final studio = DeckStudio(store);
      addTearDown(studio.dispose);
      final rows = [
        for (var row = 0; row < 12; row++)
          [
            for (var column = 0; column < 8; column++)
              '$row:$column '.padRight(SlideTable.maxCellLength, '长'),
          ],
      ];
      final deck = Deck(
        id: 'table-deck',
        title: 'Dense table deck',
        aspectRatio: ratio,
        finished: true,
        slides: [
          Slide(
            title: 'Dense table with image and bullets',
            bullets: const ['A result above the table', 'Another result'],
            imageId: 'image',
            table: SlideTable(rows: rows),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DeckWorkspacePage(studio: studio, deck: deck),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await precacheImage(
          FileImage(file),
          tester.element(find.byType(Table)),
        );
      });
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(tester.widget<Table>(find.byType(Table)).children, hasLength(12));
      expect(find.text(rows.last.last), findsOneWidget);
      final tableBounds = tester.getRect(find.byType(Table));
      final imageBounds = tester.getRect(find.byType(Image));
      expect(tableBounds.width, greaterThan(100));
      expect(tableBounds.right, lessThan(imageBounds.left));
      final lastCellBounds = tester.getRect(find.text(rows.last.last));
      expect(lastCellBounds.left, greaterThanOrEqualTo(tableBounds.left));
      expect(lastCellBounds.right, lessThanOrEqualTo(tableBounds.right + .01));
      expect(
        lastCellBounds.bottom,
        lessThanOrEqualTo(tableBounds.bottom + .01),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Dense table with image and bullets'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(Table), findsNWidgets(2));
      expect(find.text(rows.first.first), findsNWidgets(2));
      expect(find.text(rows.last.last), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a deck result in the transcript opens the workspace', (
    tester,
  ) async {
    final studio = DeckStudio();
    addTearDown(studio.dispose);
    final deck = Deck(id: 'deck', title: '季度汇报');
    studio.decks[deck.id] = deck;
    studio.activeDeck = deck;
    studio.chat = [
      const ChatEntry(
        'tool',
        'Deck "季度汇报" created with id deck (16:9).',
        callId: 'call-1',
        name: 'create_deck',
      ),
    ];
    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();
    expect(find.text('create_deck'), findsOneWidget);

    await tester.tap(find.text('create_deck'));
    await tester.pumpAndSettle();
    expect(find.byType(DeckWorkspacePage), findsOneWidget);
  });

  test('a deck does not survive into another conversation', () async {
    final store = DeckStore();
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    final deck = Deck(id: 'deck', title: '季度汇报');
    studio.decks[deck.id] = deck;
    studio.activeDeck = deck;

    await studio.newConversation();
    expect(studio.decks, isEmpty);
    expect(studio.activeDeck, isNull);

    studio.decks[deck.id] = deck;
    studio.activeDeck = deck;
    await studio.switchConversation('older');
    expect(studio.decks, isEmpty);
    expect(studio.activeDeck, isNull);
  });
}

class _ImageDeckStore extends DeckStore {
  @override
  File file(Asset asset) => File(asset.path);
}
