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
