import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';

import 'support/memory_store.dart';

void main() {
  testWidgets('the file import belongs to the Agent composer only', (
    tester,
  ) async {
    final studio = Studio(MemoryStore());
    await studio.initialize();
    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('importFiles')), findsNothing);

    await tester.tap(find.text('Agent').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('importFiles')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
