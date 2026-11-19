import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';
import 'package:imagyn/ui/gallery.dart';
import 'package:imagyn/ui/image_options.dart';
import 'package:imagyn/ui/settings.dart';

class UnusedStore implements LocalStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ComposerStudio extends Studio {
  ComposerStudio() : super(UnusedStore()) {
    onboarding = false;
    languageSetting = 'zh';
    config = const ServiceConfig(imageModel: 'gpt-image-2.5-flare');
  }
  bool reject = false;
  final result = Completer<void>();
  @override
  Future<void> submit(
    String prompt,
    bool agent,
    ImageOptions options, {
    VoidCallback? onAccepted,
  }) async {
    if (reject) throw const FormatException('missingKey');
    busy = true;
    onAccepted?.call();
    notifyListeners();
    await result.future;
    busy = false;
    notifyListeners();
  }
}

/// 虚拟作品集，记录首屏布局实际访问的作品数。
class _CountedGallery extends ListBase<Asset> {
  final asset = Asset(
    id: 'sample',
    path: 'sample.png',
    mime: 'image/png',
    prompt: 'sample',
    createdAt: DateTime(2026),
  );
  int reads = 0;

  @override
  int get length => 10000;

  @override
  Asset operator [](int index) {
    reads++;
    return asset;
  }

  @override
  set length(int value) => throw UnsupportedError('fixed length');

  @override
  void operator []=(int index, Asset value) =>
      throw UnsupportedError('read only');
}

void main() {
  for (final mode in ['light', 'dark']) {
    testWidgets('Agent desktop navigation uses the $mode chat palette', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final studio = ComposerStudio()..theme = mode;
      await tester.pumpWidget(ImagynApp(studio: studio));
      final agent = find.byKey(const ValueKey('homeAgent'));
      await tester.tap(agent);
      await tester.pumpAndSettle();
      final scheme = Theme.of(tester.element(agent)).colorScheme;
      final tile = tester.widget<ListTile>(agent);
      final rail = find.ancestor(of: agent, matching: find.byType(Material));
      expect(
        tester.widget<Material>(rail.first).color,
        scheme.surfaceContainerLow,
      );
      expect(tile.selected, isTrue);
      expect(tile.selectedTileColor, scheme.primaryContainer);
      expect((tile.leading! as Icon).color, scheme.onPrimaryContainer);
    });
  }

  for (final width in [360.0, 1280.0]) {
    testWidgets('studio ideas and header settings at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ImagynApp(studio: ComposerStudio()));
      final idea = find.text('赛博朋克雨夜');
      await tester.ensureVisible(idea);
      await tester.tap(idea);
      await tester.pumpAndSettle();
      final editor = tester.widget<TextField>(find.byType(TextField).last);
      expect(editor.controller!.text, contains('赛博朋克未来城市'));
      expect(find.byKey(const ValueKey('sidebarSettings')), findsNothing);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'accepted submission clears immediately and completion preserves the next draft',
    (tester) async {
      final studio = ComposerStudio();
      await tester.pumpWidget(ImagynApp(studio: studio));
      await tester.tap(find.byKey(const ValueKey('homeCreate')));
      await tester.pumpAndSettle();
      final input = find.widgetWithText(TextField, '描述你想画的内容……');
      await tester.enterText(input, 'first image');
      await tester.tap(find.byKey(const ValueKey('submit')));
      await tester.pump();
      expect(studio.busy, isTrue);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.widget<TextField>(input).enabled, isNot(false));
      await tester.enterText(input, 'next draft');
      studio.result.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, 'next draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local validation failure retains the prompt', (tester) async {
    final studio = ComposerStudio()..reject = true;
    await tester.pumpWidget(ImagynApp(studio: studio));
    await tester.tap(find.byKey(const ValueKey('homeCreate')));
    await tester.pumpAndSettle();
    final input = find.widgetWithText(TextField, '描述你想画的内容……');
    await tester.enterText(input, 'keep this prompt');
    await tester.tap(find.byKey(const ValueKey('submit')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(input).controller!.text,
      'keep this prompt',
    );
    expect(find.text('请在设置中添加 API 密钥。'), findsOneWidget);
  });

  testWidgets('options fit on a narrow phone and JPEG disables transparency', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageOptionsSheet(
            options: const ImageOptions(transparent: true),
            model: 'gpt-image-2.5-flare',
          ),
        ),
      ),
    );
    await tester.tap(find.text('png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('jpeg').last);
    await tester.pumpAndSettle();
    expect(find.text('on'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'gallery filters prompts and models without overflowing on phones',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final studio = ComposerStudio();
      studio.gallery = [
        Asset(
          id: 'a',
          path: 'a.png',
          mime: 'image/png',
          prompt: 'Blue whale',
          createdAt: DateTime(2026),
          parameters: const {'model': 'flare', 'size': '1024x1024'},
        ),
        Asset(
          id: 'b',
          path: 'b.png',
          mime: 'image/png',
          prompt: 'Red fox',
          createdAt: DateTime(2026),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalleryView(
              studio: studio,
              imageBuilder: (_) => const ColoredBox(color: Colors.blue),
              onPreview: (_) {},
              onAction: (_, _) {},
              onReuse: (_, _) {},
            ),
          ),
        ),
      );
      expect(find.text('Blue whale'), findsOneWidget);
      expect(find.text('Red fox'), findsOneWidget);
      expect(find.textContaining(' · 2'), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' FlArE ');
      await tester.pump();
      expect(find.text('Blue whale'), findsOneWidget);
      expect(find.text('Red fox'), findsNothing);
      expect(find.textContaining(' · 1'), findsOneWidget);
      await tester.tap(find.byType(FilterChip));
      await tester.pump();
      expect(find.textContaining(' · 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large gallery reads only the first viewport', (tester) async {
    final gallery = _CountedGallery();
    final studio = ComposerStudio()..gallery = gallery;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GalleryView(
            studio: studio,
            imageBuilder: (_) => const SizedBox(),
            onPreview: (_) {},
            onAction: (_, _) {},
            onReuse: (_, _) {},
          ),
        ),
      ),
    );
    // 给预加载区域留足余量，同时检测整表遍历。
    expect(gallery.reads, inExclusiveRange(0, 100));
  });
}
