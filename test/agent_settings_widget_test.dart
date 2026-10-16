import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';
import 'package:imagyn/main.dart';
import 'package:imagyn/ui/agent_options.dart';
import 'package:imagyn/ui/settings.dart';
import 'support/memory_store.dart';

void main() {
  testWidgets(
    'phone settings separate image and Agent fields and preserve custom prompt across tabs',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore();
      final studio = Studio(store);
      await studio.initialize();
      await tester.pumpWidget(ImagynApp(studio: studio));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byKey(const ValueKey('systemPrompt')), findsNothing);
      // The four tabs must all show their own label: the segmented button's
      // default selected tick used to eat the active segment's text.
      expect(find.byIcon(Icons.check), findsNothing);
      for (final label in ['画廊', 'Agent', '通用', '关于']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      await tester.tap(find.text('Agent').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<ApiProtocol>));
      await tester.pumpAndSettle();
      expect(find.text('OpenAI · Chat Completions'), findsWidgets);
      expect(find.text('OpenAI · Responses'), findsOneWidget);
      expect(find.text('Anthropic · Messages'), findsOneWidget);
      await tester.tap(find.text('OpenAI · Responses'));
      await tester.pumpAndSettle();
      expect(find.text('POST /responses'), findsOneWidget);
      final prompt = find.byKey(const ValueKey('systemPrompt'));
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, '我的提示词');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('systemPrompt')), findsNothing);
      await tester.tap(find.text('Agent').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(prompt).controller!.text, '我的提示词');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通用').last);
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(store.savedConfig.agentOptions.systemPrompt, '我的提示词');
      expect(store.savedConfig.protocol, ApiProtocol.responses);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conversation switches models without clearing the draft or history',
    (tester) async {
      final studio = Studio(MemoryStore());
      await studio.initialize();
      await tester.pumpWidget(ImagynApp(studio: studio));
      await tester.tap(find.text('Agent').last);
      await tester.pumpAndSettle();
      final input = find.widgetWithText(TextField, '聊聊想法，生成或修改图片……');
      await tester.enterText(input, 'keep my draft');
      await tester.tap(find.byKey(const ValueKey('switchAgentModel')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('modelId')),
        'new-agent',
      );
      await tester.tap(find.text('使用此模型'));
      await tester.pumpAndSettle();
      expect(studio.activeConfig.agentModel, 'new-agent');
      expect(tester.widget<TextField>(input).controller!.text, 'keep my draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid numeric input stays visible in the Agent editor', (
    tester,
  ) async {
    final key = GlobalKey<AgentOptionsEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentOptionsEditor(
              key: key,
              options: const AgentOptions(),
              protocol: ApiProtocol.openai,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('maxOutputTokens')),
      'abc',
    );
    expect(key.currentState!.read(), isNull);
    await tester.pump();
    expect(
      find.text(
        'Check parameter ranges and use only one sampling option for Claude.',
      ),
      findsOneWidget,
    );
  });
}
