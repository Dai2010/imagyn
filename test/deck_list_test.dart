import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';

import 'support/memory_store.dart';

void main() {
  testWidgets('the deck list reopens an older deck', (tester) async {
    final studio = Studio(MemoryStore());
    addTearDown(studio.dispose);
    await studio.initialize();
    final older = Deck(
      id: 'd1',
      title: '旧演示',
      finished: true,
      slides: [const Slide(title: '第一页', bullets: ['要点'])],
    );
    final newer = Deck(id: 'd2', title: '新演示');
    studio.decks['d1'] = older;
    studio.decks['d2'] = newer;
    studio.activeDeck = newer;

    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.tap(find.text('Agent').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('deckList')));
    await tester.pumpAndSettle();
    expect(find.text('本次对话的演示文稿'), findsOneWidget);
    expect(find.text('旧演示'), findsOneWidget);
    expect(find.text('新演示'), findsOneWidget);
    expect(find.text('1 页 · 已完成'), findsOneWidget);

    await tester.tap(find.text('旧演示'));
    await tester.pumpAndSettle();

    expect(studio.activeDeck, same(older));
    expect(find.text('第一页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
