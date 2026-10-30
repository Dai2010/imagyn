import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

/// The streaming paths only need the store to hand back reference files; a
/// request with no references never touches it.
class _UnusedStore implements LocalStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _servers = <HttpServer>[];
final _clients = <StudioApi>[];

/// Answers every request with [body] under [contentType], so a test can decide
/// whether it is looking at an SSE stream or a plain JSON reply.
Future<StudioApi> serve(
  ApiProtocol protocol,
  String body, {
  String contentType = 'text/event-stream',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _servers.add(server);
  server.listen((request) async {
    await request.drain<void>();
    request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    request.response.write(body);
    await request.response.close();
  });
  final client = StudioApi(
    ServiceConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      protocol: protocol,
      agentModel: 'agent',
    ),
    'key',
    'key',
    _UnusedStore(),
  );
  _clients.add(client);
  return client;
}

String frames(List<Object> payloads, {bool done = true}) =>
    '${payloads.map((payload) => 'data: $payload\n\n').join()}'
    '${done ? 'data: [DONE]\n\n' : ''}';

Matcher _error(String code) =>
    isA<FormatException>().having((error) => error.message, 'message', code);

void main() {
  tearDown(() async {
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
    for (final server in _servers) {
      await server.close(force: true);
    }
    _servers.clear();
  });

  test('OpenAI deltas arrive as they come, reasoning included', () async {
    final client = await serve(
      ApiProtocol.openai,
      frames([
        jsonEncode({
          'choices': [
            {
              'delta': {'reasoning_content': 'We need '},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {'reasoning_content': 'a fox.'},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Draw'},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {'content': 'ing it.'},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'name': 'generate_image', 'arguments': '{"prompt"'},
                  },
                ],
              },
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': ':"a red fox"}'},
                  },
                ],
              },
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'tool_calls',
              'delta': <String, dynamic>{},
            },
          ],
        }),
      ]),
    );
    final seen = <String>[];
    final reply = await client.converseStream(
      [const ChatEntry('user', 'draw')],
      [],
      CancelToken(),
      onDelta: (delta) {
        if (delta.text.isNotEmpty) seen.add('t:${delta.text}');
        if (delta.reasoning.isNotEmpty) seen.add('r:${delta.reasoning}');
      },
    );
    expect(seen, ['r:We need ', 'r:a fox.', 't:Draw', 't:ing it.']);
    expect(reply.text, 'Drawing it.');
    expect(reply.reasoning, 'We need a fox.');
    expect(reply.imagePrompt, 'a red fox');
  });

  test('OpenAI reads usage from the choices-less final chunk', () async {
    final client = await serve(
      ApiProtocol.openai,
      frames([
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'delta': {'content': 'ok'},
            },
          ],
        }),
        jsonEncode({
          'choices': [],
          'usage': {'prompt_tokens': 1200, 'completion_tokens': 34},
        }),
      ]),
    );
    final reply = await client.converseStream(
      [const ChatEntry('user', 'hi')],
      [],
      CancelToken(),
    );
    expect(reply.text, 'ok');
    expect(reply.usage?.input, 1200);
    expect(reply.usage?.output, 34);
  });

  test('OpenAI refuses a call from a turn that did not finish as one', () async {
    final client = await serve(
      ApiProtocol.openai,
      frames([
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'length',
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {
                      'name': 'generate_image',
                      'arguments': '{"prompt":"a fox"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
      ]),
    );
    await expectLater(
      client.converseStream(
        [const ChatEntry('user', 'draw')],
        [],
        CancelToken(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'invalidTool',
        ),
      ),
    );
  });

  test('Anthropic thinking, text and tool input stream separately', () async {
    final client = await serve(
      ApiProtocol.anthropic,
      frames([
        jsonEncode({'type': 'message_start'}),
        jsonEncode({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': ''},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'Maybe a fox.'},
        }),
        jsonEncode({
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text', 'text': ''},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'text_delta', 'text': 'On it.'},
        }),
        jsonEncode({
          'type': 'content_block_start',
          'index': 2,
          'content_block': {'type': 'tool_use', 'name': 'generate_image'},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 2,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"prompt":'},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 2,
          'delta': {'type': 'input_json_delta', 'partial_json': '"a red fox"}'},
        }),
        jsonEncode({
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
        }),
        jsonEncode({'type': 'message_stop'}),
      ]),
    );
    final reply = await client.converseStream(
      [const ChatEntry('user', 'draw')],
      [],
      CancelToken(),
    );
    expect(reply.text, 'On it.');
    expect(reply.reasoning, 'Maybe a fox.');
    expect(reply.imagePrompt, 'a red fox');
  });

  test('Anthropic joins usage from message start and delta', () async {
    final client = await serve(
      ApiProtocol.anthropic,
      frames([
        jsonEncode({
          'type': 'message_start',
          'message': {
            'usage': {'input_tokens': 900, 'output_tokens': 1},
          },
        }),
        jsonEncode({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'ok'},
        }),
        jsonEncode({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 12},
        }),
        jsonEncode({'type': 'message_stop'}),
      ]),
    );
    final reply = await client.converseStream(
      [const ChatEntry('user', 'hi')],
      [],
      CancelToken(),
    );
    expect(reply.text, 'ok');
    expect(reply.usage?.input, 900);
    expect(reply.usage?.output, 12);
  });

  test('Anthropic refuses tool input that never finished', () async {
    final client = await serve(
      ApiProtocol.anthropic,
      frames([
        jsonEncode({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'tool_use', 'name': 'generate_image'},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"prompt":"a fox'},
        }),
        jsonEncode({
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
        }),
      ]),
    );
    await expectLater(
      client.converseStream(
        [const ChatEntry('user', 'draw')],
        [],
        CancelToken(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'invalidTool',
        ),
      ),
    );
  });

  test('Responses streams text and completes with the finished turn', () async {
    final client = await serve(
      ApiProtocol.responses,
      frames([
        jsonEncode({'type': 'response.output_text.delta', 'delta': 'Here'}),
        jsonEncode({
          'type': 'response.reasoning_summary_text.delta',
          'delta': 'A fox fits.',
        }),
        jsonEncode({
          'type': 'response.function_call_arguments.delta',
          'item_id': 'fc_1',
          'delta': '{"prompt":"a red fox"}',
        }),
        jsonEncode({
          'type': 'response.completed',
          'response': {
            'status': 'completed',
            'output': [
              {
                'type': 'reasoning',
                'summary': [
                  {'type': 'summary_text', 'text': 'A fox fits.'},
                ],
              },
              {
                'type': 'message',
                'status': 'completed',
                'content': [
                  {'type': 'output_text', 'text': 'Here'},
                ],
              },
              {
                'type': 'function_call',
                'name': 'generate_image',
                'arguments': '{"prompt":"a red fox"}',
                'status': 'completed',
              },
            ],
          },
        }),
      ]),
    );
    final seen = <String>[];
    final reply = await client.converseStream(
      [const ChatEntry('user', 'draw')],
      [],
      CancelToken(),
      onDelta: (delta) => seen.add('${delta.text}${delta.reasoning}'),
    );
    expect(seen, ['Here', 'A fox fits.']);
    expect(reply.text, 'Here');
    expect(reply.reasoning, 'A fox fits.');
    expect(reply.imagePrompt, 'a red fox');
  });

  test('a service that answers without streaming is still accepted', () async {
    final client = await serve(
      ApiProtocol.openai,
      jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': 'No streaming here.'},
          },
        ],
      }),
      contentType: 'application/json',
    );
    final reply = await client.converseStream(
      [const ChatEntry('user', 'hello')],
      [],
      CancelToken(),
    );
    expect(reply.text, 'No streaming here.');
    expect(reply.imagePrompt, isNull);
  });

  test('an OpenAI stream cut off before its finish marker is refused', () async {
    // The arguments are complete; only the marker that says the turn ended is
    // missing, which is what a dropped connection looks like. Acting on it
    // would start a generation the service never confirmed.
    final client = await serve(
      ApiProtocol.openai,
      frames([
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {
                      'name': 'generate_image',
                      'arguments': '{"prompt":"a fox"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
      ], done: false),
    );
    await expectLater(
      client.converseStream(
        [const ChatEntry('user', 'draw')],
        [],
        CancelToken(),
      ),
      throwsA(_error('incompleteStream')),
    );
  });

  test('an Anthropic stream without its stop event is refused', () async {
    final client = await serve(
      ApiProtocol.anthropic,
      frames([
        jsonEncode({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'On it.'},
        }),
      ]),
    );
    await expectLater(
      client.converseStream(
        [const ChatEntry('user', 'draw')],
        [],
        CancelToken(),
      ),
      throwsA(_error('incompleteStream')),
    );
  });

  test('a Responses stream without its completed event is refused', () async {
    final client = await serve(
      ApiProtocol.responses,
      frames([
        jsonEncode({'type': 'response.output_text.delta', 'delta': 'Here'}),
      ]),
    );
    await expectLater(
      client.converseStream(
        [const ChatEntry('user', 'draw')],
        [],
        CancelToken(),
      ),
      throwsA(_error('incompleteStream')),
    );
  });
}
