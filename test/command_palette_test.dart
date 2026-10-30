import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';

import 'support/memory_store.dart';

void main() {
  testWidgets('the slash list offers /compact and /style on the Agent page', (
    tester,
  ) async {
    final studio = Studio(MemoryStore());
    await studio.initialize();
    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Agent').last);
    await tester.pumpAndSettle();

    final field = find.byType(TextField).last;
    await tester.enterText(field, '/');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compactCommand')), findsOneWidget);
    expect(find.byKey(const ValueKey('styleCommand')), findsOneWidget);

    // Narrowing the list to /c leaves the style command behind.
    await tester.enterText(field, '/c');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compactCommand')), findsOneWidget);
    expect(find.byKey(const ValueKey('styleCommand')), findsNothing);
  });

  testWidgets('the gallery lists no /compact, since only the Agent uses it', (
    tester,
  ) async {
    final studio = Studio(MemoryStore());
    await studio.initialize();
    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('homeCreate')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '/');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compactCommand')), findsNothing);
    expect(find.byKey(const ValueKey('styleCommand')), findsOneWidget);
  });
}
