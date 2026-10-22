import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

class _UnusedStore implements LocalStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _openAiCall({String? finishReason, String? refusal}) => {
  'choices': [
    {
      if (finishReason != null) 'finish_reason': finishReason,
      'message': {
        'content': null,
        if (refusal != null) 'refusal': refusal,
        'tool_calls': [
          {
            'function': {
              'name': 'generate_image',
              'arguments': '{"prompt":"a fox"}',
            },
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _anthropicCall({String? stopReason}) => {
  if (stopReason != null) 'stop_reason': stopReason,
  'content': [
    {
      'type': 'tool_use',
      'name': 'generate_image',
      'input': {'prompt': 'a fox'},
    },
  ],
};

void main() {
  test(
    'OpenAI refuses tool execution when the turn did not finish as a call',
    () {
      for (final reason in ['length', 'content_filter', 'stop']) {
        expect(
          () => parseAgentReply(
            _openAiCall(finishReason: reason),
            ApiProtocol.openai,
          ),
          throwsA(_formatError('invalidTool')),
          reason: reason,
        );
      }
    },
  );

  test(
    'Anthropic refuses tool execution when the turn did not finish as a call',
    () {
      for (final reason in [
        'max_tokens',
        'pause_turn',
        'refusal',
        'end_turn',
      ]) {
        expect(
          () => parseAgentReply(
            _anthropicCall(stopReason: reason),
            ApiProtocol.anthropic,
          ),
          throwsA(_formatError('invalidTool')),
          reason: reason,
        );
      }
    },
  );

  test(
    'finished image calls and compatible missing stop metadata still work',
    () {
      for (final reason in [null, 'tool_calls']) {
        expect(
          parseAgentReply(
            _openAiCall(finishReason: reason),
            ApiProtocol.openai,
          ).imagePrompt,
          'a fox',
        );
      }
      for (final reason in [null, 'tool_use']) {
        expect(
          parseAgentReply(
            _anthropicCall(stopReason: reason),
            ApiProtocol.anthropic,
          ).imagePrompt,
          'a fox',
        );
      }
    },
  );

  test('OpenAI displays a refusal with null content', () {
    final reply = parseAgentReply({
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {'content': null, 'refusal': 'Cannot help with this.'},
        },
      ],
    }, ApiProtocol.openai);
    expect(reply.text, 'Cannot help with this.');
    expect(reply.imagePrompt, isNull);
  });

  test('a refusal cannot also trigger image generation', () {
    expect(
      () => parseAgentReply(
        _openAiCall(finishReason: 'tool_calls', refusal: 'Cannot help.'),
        ApiProtocol.openai,
      ),
      throwsA(_formatError('invalidTool')),
    );
  });

  test('video credentials fall back from video to image to main', () {
    final video = StudioApi(
      const ServiceConfig(),
      'main',
      '',
      _UnusedStore(),
      videoKey: 'clip',
    );
    addTearDown(video.close);
    expect(video.videoHeaders['Authorization'], 'Bearer clip');

    final images = StudioApi(
      const ServiceConfig(),
      'main',
      'picture',
      _UnusedStore(),
    );
    addTearDown(images.close);
    expect(images.videoHeaders['Authorization'], 'Bearer picture');

    final main = StudioApi(const ServiceConfig(), 'main', '', _UnusedStore());
    addTearDown(main.close);
    expect(main.videoHeaders['Authorization'], 'Bearer main');
  });

  test(
    'decoded Base64 images enforce the same byte limit as downloads',
    () async {
      final bytes = Uint8List(StudioApi.maxImageBytes + 1);
      bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
      final client = StudioApi(const ServiceConfig(), '', '', _UnusedStore());
      addTearDown(client.close);
      await expectLater(
        client.downloadImages([
          'data:image/png;base64,${base64Encode(bytes)}',
        ], CancelToken()),
        throwsA(_formatError('imageTooLarge')),
      );
    },
  );

  test('SSE source limit counts comments and stops reading early', () async {
    // Reuse one chunk so this exercises the full response limit without
    // allocating a response-sized test fixture or retaining any image data.
    final comment = Uint8List(1024 * 1024);
    comment.fillRange(0, comment.length, 58);
    comment.last = 10;
    var emitted = 0;
    Stream<List<int>> source() async* {
      for (var i = 0; i < 422; i++) {
        emitted++;
        yield comment;
      }
    }

    await expectLater(
      readImageResponse(source(), eventStream: true),
      throwsA(_formatError('imageTooLarge')),
    );
    expect(emitted, lessThanOrEqualTo(421));
  });
}

Matcher _formatError(String message) =>
    isA<FormatException>().having((error) => error.message, 'message', message);
