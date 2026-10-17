import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';

void main() {
  group('parseAgentReply', () {
    test('returns plain text when the model asks for no image', () {
      final reply = parseAgentReply({
        'choices': [
          {'message': {'content': 'Tell me more about the mood.'}},
        ],
      }, ApiProtocol.openai);
      expect(reply.text, 'Tell me more about the mood.');
      expect(reply.imagePrompt, isNull);
    });

    test('accepts an OpenAI function call as an image request', () {
      final reply = parseAgentReply({
        'choices': [
          {
            'message': {
              'content': 'Making it now.',
              'tool_calls': [
                {
                  'function': {
                    'name': 'generate_image',
                    'arguments': '{"prompt":"a red fox"}',
                  },
                },
              ],
            },
          },
        ],
      }, ApiProtocol.openai);
      expect(reply.text, 'Making it now.');
      expect(reply.imagePrompt, 'a red fox');
    });

    test('accepts an Anthropic tool_use block as an image request', () {
      final reply = parseAgentReply({
        'content': [
          {'type': 'text', 'text': 'Sure.'},
          {
            'type': 'tool_use',
            'name': 'generate_image',
            'input': {'prompt': 'a blue fox'},
          },
        ],
      }, ApiProtocol.anthropic);
      expect(reply.text, 'Sure.');
      expect(reply.imagePrompt, 'a blue fox');
    });

    test('carries the aspect ratio each protocol puts on the call', () {
      final openai = parseAgentReply({
        'choices': [
          {
            'message': {
              'tool_calls': [
                {
                  'function': {
                    'name': 'generate_image',
                    'arguments':
                        '{"prompt":"a poster","aspect_ratio":"16:9"}',
                  },
                },
              ],
            },
          },
        ],
      }, ApiProtocol.openai);
      expect(openai.aspectRatio, '16:9');

      final anthropic = parseAgentReply({
        'content': [
          {
            'type': 'tool_use',
            'name': 'generate_image',
            'input': {'prompt': 'a poster', 'aspect_ratio': '2:3'},
          },
        ],
      }, ApiProtocol.anthropic);
      expect(anthropic.aspectRatio, '2:3');

      final responses = parseAgentReply({
        'status': 'completed',
        'output': [
          {
            'type': 'function_call',
            'name': 'generate_image',
            'arguments': '{"prompt":"a poster","aspect_ratio":"1:1"}',
          },
        ],
      }, ApiProtocol.responses);
      expect(responses.aspectRatio, '1:1');
    });

    test('rejects a tool other than the image tool', () {
      expect(
        () => parseAgentReply({
          'choices': [
            {
              'message': {
                'tool_calls': [
                  {'function': {'name': 'run_shell', 'arguments': '{"cmd":"ls"}'}},
                ],
              },
            },
          ],
        }, ApiProtocol.openai),
        throwsA(_formatError('unsupportedTool')),
      );
    });

    test('rejects two generation requests in one turn', () {
      Map<String, dynamic> call(String prompt) => {
        'function': {'name': 'generate_image', 'arguments': '{"prompt":"$prompt"}'},
      };
      expect(
        () => parseAgentReply({
          'choices': [
            {
              'message': {
                'tool_calls': [call('a'), call('b')],
              },
            },
          ],
        }, ApiProtocol.openai),
        throwsA(_formatError('multipleCalls')),
      );
    });

    test('rejects an empty reply', () {
      expect(
        () => parseAgentReply({'choices': []}, ApiProtocol.openai),
        throwsA(_formatError('invalidResponse')),
      );
      expect(
        () => parseAgentReply({'content': 'not a list'}, ApiProtocol.anthropic),
        throwsA(_formatError('invalidResponse')),
      );
    });

    test('rejects malformed tool arguments', () {
      expect(
        () => parseAgentReply({
          'choices': [
            {
              'message': {
                'tool_calls': [
                  {'function': {'name': 'generate_image', 'arguments': 'not json'}},
                ],
              },
            },
          ],
        }, ApiProtocol.openai),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('imageOutputs', () {
    test('accepts base64 payloads', () {
      expect(imageOutputs({
        'data': [
          {'b64_json': 'AA=='},
        ],
      }), ['data:image/*;base64,AA==']);
    });

    test('accepts remote URLs', () {
      expect(imageOutputs({
        'data': [
          {'url': 'https://images.example.com/a.png'},
        ],
      }), ['https://images.example.com/a.png']);
    });

    test('rejects an empty or shapeless payload', () {
      expect(() => imageOutputs({'data': []}), throwsA(_formatError('noImage')));
      expect(() => imageOutputs({'data': [{}]}), throwsA(_formatError('noImage')));
      expect(() => imageOutputs({'data': 'nope'}), throwsA(_formatError('noImage')));
    });
  });

  group('objectResponse', () {
    test('decodes a JSON body that arrives as a string', () {
      expect(objectResponse('{"id":"abc"}'), {'id': 'abc'});
    });

    test('rejects a non-object body', () {
      expect(() => objectResponse('[1,2]'), throwsA(_formatError('invalidResponse')));
      expect(() => objectResponse(null), throwsA(_formatError('invalidResponse')));
    });
  });

  group('validateToolCall', () {
    test('trims and accepts a usable prompt', () {
      expect(
        validateToolCall({'prompt': '  a cat  '}),
        (prompt: 'a cat', aspectRatio: null),
      );
    });

    test('keeps a known aspect ratio and reads auto as no choice', () {
      expect(
        validateToolCall({'prompt': 'a cat', 'aspect_ratio': '16:9'}).aspectRatio,
        '16:9',
      );
      expect(
        validateToolCall({'prompt': 'a cat', 'aspect_ratio': 'auto'}).aspectRatio,
        isNull,
      );
    });

    test('rejects a missing, empty or oversized prompt', () {
      expect(() => validateToolCall('a cat'), throwsA(_formatError('invalidTool')));
      expect(() => validateToolCall({'prompt': '   '}),
          throwsA(_formatError('invalidTool')));
      expect(() => validateToolCall({'prompt': 5}),
          throwsA(_formatError('invalidTool')));
      expect(() => validateToolCall({'prompt': 'x' * 32001}),
          throwsA(_formatError('invalidTool')));
    });

    test('rejects a ratio the app cannot send', () {
      expect(
        () => validateToolCall({'prompt': 'a cat', 'aspect_ratio': '7:5'}),
        throwsA(_formatError('invalidTool')),
      );
      expect(() => validateToolCall({'prompt': 'a cat', 'aspect_ratio': 16}),
          throwsA(_formatError('invalidTool')));
    });
  });
}

Matcher _formatError(String message) => isA<FormatException>()
    .having((error) => error.message, 'message', message);
