import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/styles.dart';
import 'package:imagyn/core/video.dart';

void main() {
  test('video options validate, round-trip and map to a size', () {
    const options = VideoOptions(
      ratio: '9:16',
      resolution: '1080p',
      seconds: 8,
      watermark: true,
      seed: 42,
      style: 'cel',
    );
    expect(VideoOptions.fromJson(options.toJson()).toJson(), options.toJson());
    expect(options.size, '1080x1920');
    expect(options.requestFields()['duration'], 8);
    expect(options.requestFields()['camera_fixed'], isFalse);

    expect(
      () => const VideoOptions(ratio: '2:1').validate(),
      throwsFormatException,
    );
    expect(
      () => const VideoOptions(seconds: 30).validate(),
      throwsFormatException,
    );
    expect(
      () => const VideoOptions(seed: -2).validate(),
      throwsFormatException,
    );
    expect(const VideoOptions(ratio: 'adaptive').size, isEmpty);
  });

  test('every built-in video model has an id and a face', () {
    final ids = videoModels.map((model) => model.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final model in videoModels) {
      expect(model.id.trim(), isNotEmpty);
      expect(model.label.trim(), isNotEmpty);
    }
  });

  test('task objects are read from either gateway shape', () {
    final openAi = parseVideoTask(const {
      'id': 'video_123',
      'status': 'in_progress',
    });
    expect(openAi.id, 'video_123');
    expect(openAi.state, 'running');

    final taskId = parseVideoTask(const {
      'task_id': 't-9',
      'task_status': 'succeeded',
      'url': 'https://cdn.example/clip.mp4',
    });
    expect(taskId.id, 't-9');
    expect(taskId.state, 'done');
    expect(taskId.url, 'https://cdn.example/clip.mp4');

    final nested = parseVideoTask(const {
      'id': 'v2',
      'status': 'completed',
      'data': [
        {'video_url': 'https://cdn.example/b.mp4'},
      ],
    });
    expect(nested.url, 'https://cdn.example/b.mp4');

    final failed = parseVideoTask(const {
      'id': 'v3',
      'status': 'failed',
      'error': {'message': 'content rejected'},
    });
    expect(failed.state, 'failed');
    expect(failed.message, 'content rejected');

    final unknown = parseVideoTask(const {'id': 'v4'});
    expect(unknown.state, 'pending');
  });

  test('the style block rides inside the video prompt', () {
    const options = VideoOptions(style: 'cel');
    final prompt = videoPrompt('一只猫在窗台', options, const []);
    expect(prompt, startsWith('一只猫在窗台\n\nStyle: '));
    expect(prompt, contains('cel shading'));

    const plain = VideoOptions();
    expect(videoPrompt('一只猫', plain, const []), '一只猫');
  });

  test('generate_video takes the documented arguments and nothing else', () {
    final call = validateVideoCall(const {'prompt': ' 一只猫 ', 'style': 'cel'});
    expect(call.prompt, '一只猫');
    expect(call.model, isEmpty);
    expect(call.ratio, '16:9');
    expect(call.seconds, 5);
    expect(call.seed, -1);
    expect(call.style, 'cel');

    expect(
      validateVideoCall(const {'prompt': 'x', 'model': ' veo-3-1 '}).model,
      'veo-3-1',
    );
    expect(validateVideoCall(const {'prompt': 'x'}).style, isEmpty);
    expect(
      () => validateVideoCall(const {'prompt': 'x', 'model': 'two words'}),
      throwsFormatException,
    );
    expect(
      () => validateVideoCall(const {'prompt': 'x', 'ratio': '2:1'}),
      throwsFormatException,
    );
    expect(
      () => validateVideoCall(const {'prompt': 'x', 'style': 'my-pack'}),
      throwsFormatException,
      reason: 'custom packs never leave the device',
    );
    expect(
      () => validateVideoCall(const {'prompt': ' '}),
      throwsFormatException,
    );

    final parameters = videoTool['parameters'] as Map;
    expect((parameters['properties'] as Map)['style']['enum'], styleChoices);
    expect(parameters['required'], contains('camera_fixed'));
    expect(parameters['required'], contains('model'));
    expect(agentTools.map((tool) => tool['name']), contains('generate_video'));
  });
}
