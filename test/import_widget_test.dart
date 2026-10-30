import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';

import 'support/memory_store.dart';

void main() {
  testWidgets('one attach button offers files only on the Agent page', (
    tester,
  ) async {
    final studio = Studio(MemoryStore());
    await studio.initialize();
    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('homeCreate')));
    await tester.pumpAndSettle();

    // The gallery can add references but has nowhere to send a document.
    await tester.tap(find.byKey(const ValueKey('attach')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('addReferences')), findsOneWidget);
    expect(find.byKey(const ValueKey('importFiles')), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('homeAgent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attach')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('importFiles')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
