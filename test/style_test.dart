import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/styles.dart';

void main() {
  test('every built-in pack is complete and reachable by the Agent', () {
    final ids = builtInStyles.map((style) => style.id).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: 'ids must be unique');
    expect(ids, builtInStyleIds);
    expect(styleChoices, ['auto', ...builtInStyleIds]);
    for (final style in builtInStyles) {
      expect(style.label, startsWith('style'));
      expect(style.words.trim(), isNotEmpty);
      // The whole point of the packs is naming what to avoid, so none ships
      // without it.
      expect(style.avoid.trim(), isNotEmpty);
      expect(style.isBuiltIn, isTrue);
    }
  });

  test('style words are appended after the prompt, never mixed into it', () {
    final cel = styleById(const [], 'cel')!;
    final composed = withStyle('初音未来站在舞台上', cel);
    expect(composed, startsWith('初音未来站在舞台上\n\nStyle: '));
    expect(composed, contains('cel shading'));
    expect(composed, contains('\nAvoid: '));
    expect(composed, endsWith(cel.avoid));

    final plain = ImageStyle.custom(
      id: 'c1',
      name: '我的画风',
      words: 'thick outlines, muted colors',
    );
    final bare = withStyle('一只猫', plain);
    expect(bare, contains('Style: thick outlines, muted colors'));
    expect(bare, isNot(contains('Avoid:')));

    expect(withStyle('一只猫', null), '一只猫');
    expect(withStyle('  一只猫  ', null), '  一只猫  ');
  });

  test('custom packs are validated and survive a round trip', () {
    final style = ImageStyle.custom(
      id: 'c42',
      name: ' 厚涂 ',
      words: ' painterly edges ',
      avoid: 'glossy',
    );
    expect(style.label, '厚涂');
    expect(style.words, 'painterly edges');
    expect(style.avoid, 'glossy');
    expect(style.isBuiltIn, isFalse);
    expect(ImageStyle.fromJson(style.toJson()).toJson(), style.toJson());

    expect(
      () => ImageStyle.custom(id: 'c', name: '  ', words: 'x'),
      throwsFormatException,
      reason: 'blank name',
    );
    expect(
      () => ImageStyle.custom(id: 'c', name: 'n', words: '  '),
      throwsFormatException,
      reason: 'blank words',
    );
    expect(
      () => ImageStyle.custom(
        id: 'c',
        name: 'x' * (ImageStyle.maxName + 1),
        words: 'w',
      ),
      throwsFormatException,
      reason: 'long name',
    );
    expect(
      () => ImageStyle.fromJson(const {'id': 1, 'name': 'n', 'words': 'w'}),
      throwsFormatException,
    );
    expect(styleById(const [], 'nope'), isNull);
  });

  test('the chosen style is saved with the options, not sent to the API', () {
    const options = ImageOptions(style: 'cel');
    expect(options.toJson()['style'], 'cel');
    expect(ImageOptions.fromJson(options.toJson()).style, 'cel');
    expect(const ImageOptions().toJson().containsKey('style'), isFalse);
    expect(ImageOptions.fromJson(const {}).style, '');
    expect(options.requestFields().containsKey('style'), isFalse);
    expect(options.copyWith(size: '1024x1024').style, 'cel');
    expect(options.copyWith(style: '').style, '');
  });

  test('the Agent may name a built-in style, and auto keeps the app choice', () {
    expect(validateToolCall({'prompt': 'a cat', 'style': 'cel'}).style, 'cel');
    expect(validateToolCall({'prompt': 'a cat', 'style': 'auto'}).style, isNull);
    expect(validateToolCall({'prompt': 'a cat'}).style, isNull);
    expect(
      () => validateToolCall({'prompt': 'a cat', 'style': 'my-own-pack'}),
      throwsFormatException,
      reason: 'custom packs never leave the device',
    );
    expect(
      () => validateToolCall({'prompt': 'a cat', 'style': 3}),
      throwsFormatException,
    );

    final parameters = imageTool['parameters'] as Map;
    final style = (parameters['properties'] as Map)['style'] as Map;
    expect(style['enum'], styleChoices);
    expect(parameters['required'], contains('style'));
  });

  test('a /style line becomes prompt text and can be taken back', () {
    final cel = styleById(const [], 'cel')!;
    final block = styleBlock(cel);

    // The command is the line being typed, so a prompt written first stays.
    expect(insertStyle('/style', cel), block);
    expect(insertStyle('一只猫\n/style', cel), '一只猫\n\n$block');
    expect(insertStyle('一只猫', cel), '一只猫\n\n$block');

    expect(styleIn('/style', const []), isNull);
    final filled = insertStyle('一只猫\n/style', cel);
    expect(styleIn(filled, const []), cel);
    expect(styleIn('没有画风的句子', const []), isNull);

    expect(removeStyle(filled, cel), '一只猫');
    expect(removeStyle(block, cel), '');
    expect(removeStyle('一只猫', cel), '一只猫');
  });
}
