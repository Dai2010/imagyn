import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';
import 'package:imagyn/ui/deck_workspace.dart';

import 'support/memory_store.dart';

class DeckStore extends MemoryStore {
  @override
  Future<Asset?> asset(String id) async => null;
}

class DeckStudio extends Studio {
  DeckStudio([MemoryStore? store]) : super(store ?? DeckStore()) {
    onboarding = false;
    languageSetting = 'zh';
    config = const ServiceConfig(agentModel: 'agent', imageModel: 'image');
  }
}

Map<String, dynamic> toolCall(String name, Map<String, dynamic> arguments) => {
  'content': '',
  'tool_calls': [
    {
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(arguments)},
    },
  ],
};

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
    expect(find.text('正在构思第一页……'), findsOneWidget);

    deck.slides.add(const Slide(title: '第一页', bullets: ['要点一', '要点二']));
    studio.notifyListeners();
    await tester.pump();
    expect(find.text('第一页'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('正在构思第一页……'), findsNothing);

    deck.slides.add(const Slide(title: '第二页', bullets: ['另一要点']));
    studio.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('第二页'), findsOneWidget);

    deck.slides.removeAt(0);
    studio.notifyListeners();
    await tester.pump();
    // The old page stays in the tree while it shrinks away.
    expect(find.text('第一页'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('第一页'), findsNothing);
    expect(find.text('第二页'), findsOneWidget);

    deck.finished = true;
    studio.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('已完成'), findsOneWidget);
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

  test('one turn can create, fill and finish a deck', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final subscription = server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      // add_slide and finish_deck name the deck by the id create_deck returned.
      String? deckId;
      for (final message in body['messages'] as List? ?? []) {
        final content = (message as Map)['content'];
        if (content is! String) continue;
        final match = RegExp(r'created with id (\S+) \(').firstMatch(content);
        if (match != null) deckId = match.group(1);
      }
      final message = switch (requests++) {
        0 => toolCall('create_deck', {
          'title': '测试演示',
          'aspect_ratio': '16:9',
        }),
        1 => toolCall('add_slide', {
          'deck': deckId,
          'title': '第一页',
          'bullets': ['要点'],
          'image_id': '',
        }),
        2 => toolCall('finish_deck', {'deck': deckId}),
        _ => {'content': '演示文稿做好了。'},
      };
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
    final store = DeckStore()
      ..savedConfig = ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'agent',
        streamAgent: false,
      );
    final studio = DeckStudio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    await studio.submit('做一个演示文稿', true, const ImageOptions());

    expect(studio.error, isNull);
    final deck = studio.decks.values.single;
    expect(studio.activeDeck, same(deck));
    expect(deck.title, '测试演示');
    expect(deck.slides.single.title, '第一页');
    expect(deck.finished, isTrue);
    expect(studio.runningTool, isNull);
    expect(studio.chat.last.text, '演示文稿做好了。');
    expect(requests, 4);
  });
}
