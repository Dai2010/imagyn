import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';

void main() {
  group('ServiceConfig.endpoint', () {
    test('appends the path to the base URL', () {
      expect(
        const ServiceConfig(baseUrl: 'https://api.example.com/v1').endpoint('models').toString(),
        'https://api.example.com/v1/models',
      );
    });

    test('ignores trailing slashes on the base URL', () {
      expect(
        const ServiceConfig(baseUrl: 'https://api.example.com/v1///').endpoint('models').toString(),
        'https://api.example.com/v1/models',
      );
    });

    test('rejects a base URL that is not a plain http(s) address', () {
      for (final base in [
        '',
        'ftp://api.example.com/v1',
        'https://api.example.com/v1?token=x',
        'https://api.example.com/v1#frag',
        'https://user:secret@api.example.com/v1',
        'https:///v1',
      ]) {
        expect(
          () => ServiceConfig(baseUrl: base).endpoint('models'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', 'invalidEndpoint')),
          reason: base,
        );
      }
    });
  });

  group('ServiceConfig.imageEndpoint', () {
    test('falls back to the agent service when no image service is set', () {
      expect(
        const ServiceConfig(baseUrl: 'https://api.example.com/v1')
            .imageEndpoint('images/generations')
            .toString(),
        'https://api.example.com/v1/images/generations',
      );
    });

    test('uses the separate image service when one is set', () {
      expect(
        const ServiceConfig(baseUrl: 'https://api.example.com/v1', imageBaseUrl: 'https://img.example.com/v2/')
            .imageEndpoint('images/edits')
            .toString(),
        'https://img.example.com/v2/images/edits',
      );
    });

    test('video falls back from its own service to images to the main one', () {
      const main = ServiceConfig(baseUrl: 'https://api.example.com/v1');
      expect(
        main.videoEndpoint('videos').toString(),
        'https://api.example.com/v1/videos',
      );
      const images = ServiceConfig(
        baseUrl: 'https://api.example.com/v1',
        imageBaseUrl: 'https://img.example.com/v2/',
      );
      expect(
        images.videoEndpoint('videos').toString(),
        'https://img.example.com/v2/videos',
      );
      const video = ServiceConfig(
        baseUrl: 'https://api.example.com/v1',
        imageBaseUrl: 'https://img.example.com/v2',
        videoBaseUrl: 'https://clip.example.com/v3/',
      );
      expect(
        video.videoEndpoint('videos').toString(),
        'https://clip.example.com/v3/videos',
      );
    });
  });

  group('ServiceConfig JSON', () {
    test('survives a round trip', () {
      const original = ServiceConfig(
        baseUrl: 'https://api.example.com/v1',
        protocol: ApiProtocol.anthropic,
        imageModel: 'img-1',
        imageBaseUrl: 'https://img.example.com/v2',
        videoBaseUrl: 'https://clip.example.com/v3',
        agentModel: 'chat-1',
        vision: true,
        maxReferences: 3,
        proxy: 'http://127.0.0.1:8080',
      );
      final copy = ServiceConfig.fromJson(original.toJson());
      expect(copy.baseUrl, original.baseUrl);
      expect(copy.protocol, ApiProtocol.anthropic);
      expect(copy.imageModel, 'img-1');
      expect(copy.imageBaseUrl, 'https://img.example.com/v2');
      expect(copy.videoBaseUrl, 'https://clip.example.com/v3');
      expect(copy.agentModel, 'chat-1');
      expect(copy.vision, isTrue);
      expect(copy.maxReferences, 3);
      expect(copy.proxy, 'http://127.0.0.1:8080');
    });

    test('defaults to the OpenAI protocol and no vision', () {
      final config = ServiceConfig.fromJson(const {});
      expect(config.protocol, ApiProtocol.openai);
      expect(config.vision, isFalse);
      expect(config.maxReferences, 4);
    });

    test('clamps the reference limit into 1..16', () {
      expect(ServiceConfig.fromJson(const {'maxReferences': 0}).maxReferences, 1);
      expect(ServiceConfig.fromJson(const {'maxReferences': -3}).maxReferences, 1);
      expect(ServiceConfig.fromJson(const {'maxReferences': 99}).maxReferences, 16);
      expect(ServiceConfig.fromJson(const {'maxReferences': 5}).maxReferences, 5);
    });
  });

  group('records', () {
    test('an asset survives a round trip, including its parent version', () {
      final asset = Asset(
        id: 'a1',
        path: 'assets/a1.png',
        mime: 'image/png',
        prompt: 'a red fox',
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        parentId: 'a0',
      );
      final copy = Asset.fromJson(asset.toJson());
      expect(copy.id, 'a1');
      expect(copy.path, 'assets/a1.png');
      expect(copy.prompt, 'a red fox');
      expect(copy.createdAt, asset.createdAt);
      expect(copy.parentId, 'a0');
    });

    test('a chat entry survives a round trip', () {
      const entry = ChatEntry('assistant', 'here it is', assetIds: ['a1', 'a2']);
      final copy = ChatEntry.fromJson(entry.toJson());
      expect(copy.role, 'assistant');
      expect(copy.text, 'here it is');
      expect(copy.assetIds, ['a1', 'a2']);
    });
  });

  test('the pre-deck prompt is upgraded but a custom prompt is kept', () {
    expect(
      AgentOptions.fromJson({'systemPrompt': legacyAgentPrompt}).systemPrompt,
      defaultAgentPrompt,
    );
    expect(
      AgentOptions.fromJson({'systemPrompt': 'my own prompt'}).systemPrompt,
      'my own prompt',
    );
    expect(AgentOptions.fromJson(const {}).systemPrompt, defaultAgentPrompt);
  });

  test('the image tool asks for a prompt, a ratio and a quality', () {
    final parameters = imageTool['parameters'] as Map;
    final properties = parameters['properties'] as Map;
    expect(imageTool['name'], 'generate_image');
    expect(properties.keys, [
      'prompt',
      'aspect_ratio',
      'quality',
      'style',
      'reference_ids',
    ]);
    // OpenAI strict tools require every property to be listed as required.
    expect(parameters['required'], [
      'prompt',
      'aspect_ratio',
      'quality',
      'style',
      'reference_ids',
    ]);
    expect(parameters['additionalProperties'], isFalse);
    expect(
      ((properties['aspect_ratio'] as Map)['enum'] as List).toSet(),
      {'auto', ...sizePresets.keys},
    );
    expect(
      ((properties['quality'] as Map)['enum'] as List).toSet(),
      {'auto', 'low', 'medium', 'high'},
    );
  });

  test('reference ids are trimmed, de-duplicated and capped', () {
    final picked = validateToolCall({
      'prompt': 'x',
      'reference_ids': [' a ', 'a', '', 'b'],
    });
    expect(picked.referenceIds, ['a', 'b']);
    expect(validateToolCall({'prompt': 'x'}).referenceIds, isEmpty);
    expect(
      () => validateToolCall({'prompt': 'x', 'reference_ids': 'a'}),
      throwsFormatException,
    );
    expect(
      () => validateToolCall({
        'prompt': 'x',
        'reference_ids': List.generate(11, (index) => '$index'),
      }),
      throwsFormatException,
    );
  });

  test('the gallery tools are offered to the model', () {
    expect(
      agentTools.map((tool) => tool['name']),
      containsAll(['list_images', 'delete_image']),
    );
    final list = agentTools.firstWhere((tool) => tool['name'] == 'list_images');
    expect((list['parameters'] as Map)['required'], ['limit', 'query']);
  });
}
