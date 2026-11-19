import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/main.dart';
import 'package:imagyn/ui/graphite_frame.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('Graphite caption dispatches native window commands', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final commands = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call.method);
      return call.method == 'isFocused';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => GraphiteFrame(child: child!),
      home: const Scaffold(),
    ));
    await tester.pumpAndSettle();
    for (final mark in ['−', '▴', '×']) {
      await tester.tap(find.text(mark));
      await tester.pump();
    }
    expect(commands, containsAllInOrder(['minimize', 'maximize', 'close']));
    expect(tester.takeException(), isNull);
  });

  test('desktop themes ask for the platform UI font', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final windows = studioTheme(Brightness.light);
    expect(windows.textTheme.bodyMedium?.fontFamily, 'Segoe UI');
    expect(
      windows.textTheme.bodyMedium?.fontFamilyFallback,
      contains('Microsoft YaHei'),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final linux = studioTheme(Brightness.light);
    expect(linux.textTheme.bodyMedium?.fontFamily, 'Noto Sans');
    expect(
      linux.textTheme.bodyMedium?.fontFamilyFallback,
      contains('Noto Sans CJK SC'),
    );
  });

  test('mobile and macOS keep the font Material already picks', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(studioTheme(Brightness.light).textTheme.bodyMedium?.fontFamily, isNot('Segoe UI'));

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(studioTheme(Brightness.light).textTheme.bodyMedium?.fontFamily, isNot('Segoe UI'));
  });
}
