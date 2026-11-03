import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';

void main() {
  group('model entries', () {
    test('a full entry survives a save and a load', () {
      const entry = ModelEntry(
        id: 'glm-5.3',
        alias: 'GLM 主力',
        capabilities: {
          ModelCapability.vision,
          ModelCapability.reasoning,
          ModelCapability.toolUse,
        },
        contextWindow: 1000000,
        maxOutput: 128000,
      );
      final back = ModelEntry.fromJson(entry.toJson());
      expect(back.id, 'glm-5.3');
      expect(back.alias, 'GLM 主力');
      expect(back.capabilities, entry.capabilities);
      expect(back.contextWindow, 1000000);
      expect(back.maxOutput, 128000);
    });

    test('an entry that was never filled in keeps no settings', () {
      final json = const ModelEntry(id: 'dall-e-3').toJson();
      expect(json, {'id': 'dall-e-3'});
      final back = ModelEntry.fromJson(json);
      expect(back.capabilities, isEmpty);
      expect(back.contextWindow, 0);
      expect(back.maxOutput, 0);
    });

    test('an unknown capability is dropped rather than crashing', () {
      final back = ModelEntry.fromJson({
        'id': 'x',
        'capabilities': ['vision', 'embeddings', 42],
      });
      expect(back.capabilities, {ModelCapability.vision});
    });

    test('the name falls back to the id, and never to blanks', () {
      expect(const ModelEntry(id: 'a', alias: '  ').name, 'a');
      expect(const ModelEntry(id: 'a', alias: ' A ').name, 'A');
    });

    test('a broken saved list loses only the rows that are broken', () {
      final list = ModelEntry.listFromJson([
        {'id': 'ok'},
        {'id': '  '},
        {'alias': 'no id at all'},
        'not a map',
        {'id': 'fine', 'contextWindow': 8000},
      ]);
      expect([for (final entry in list) entry.id], ['ok', 'fine']);
      expect(list.last.contextWindow, 8000);
    });

    test('duplicates collapse and ids lose their padding', () {
      final list = ModelEntry.normalize(const [
        ModelEntry(id: ' a '),
        ModelEntry(id: 'a', alias: 'second'),
        ModelEntry(id: ''),
        ModelEntry(id: 'b'),
      ]);
      expect([for (final entry in list) entry.id], ['a', 'b']);
    });

    test('an unknown token count stays zero, which means unknown', () {
      final back = ModelEntry.fromJson({'id': 'x', 'contextWindow': 'later'});
      expect(back.contextWindow, 0);
    });
  });
}
