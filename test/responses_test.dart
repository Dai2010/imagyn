import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

class ReferenceStore implements LocalStore {
  ReferenceStore(this.image);
  final File image;
  @override
  File file(Asset asset) => image;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> call({
  String name = 'generate_image',
  String arguments = '{"prompt":"a whale"}',
  String status = 'completed',
}) => {
  'type': 'function_call',
  'name': name,
  'arguments': arguments,
  'status': status,
};

void main() {
  test(
    'Responses protocol persists without changing legacy OpenAI selection',
    () {
      final config = ServiceConfig.fromJson(
        const ServiceConfig(protocol: ApiProtocol.responses).toJson(),
      );
      expect(config.protocol, ApiProtocol.responses);
      expect(
        () => const AgentOptions(
          maxOutputTokens: 1,
        ).validate(ApiProtocol.responses),
        throwsFormatException,
      );
      expect(config.protocol.chatPath, 'responses');
      expect(
        ServiceConfig.fromJson({'protocol': 'openai'}).protocol.chatPath,
        'chat/completions',
      );
      expect(ApiProtocol.values.map((p) => p.label).toSet().length, 3);
    },
  );

  test(
    'Responses combines text blocks and one image tool call, ignoring reasoning',
    () {
      final reply = parseAgentReply({
        'status': 'completed',
        'output': [
          {'type': 'reasoning', 'summary': []},
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'One'},
              {'type': 'output_text', 'text': 'Two'},
            ],
          },
          call(),
        ],
      }, ApiProtocol.responses);
      expect(reply.text, 'One\nTwo');
      expect(reply.imagePrompt, 'a whale');
    },
  );

  test('Responses refusal is shown as text and never generates an image', () {
    final reply = parseAgentReply({
      'output': [
        {
          'type': 'message',
          'content': [
            {'type': 'refusal', 'refusal': 'Cannot help.'},
          ],
        },
      ],
    }, ApiProtocol.responses);
    expect(reply.text, 'Cannot help.');
    expect(reply.imagePrompt, isNull);
  });

  test(
    'Responses rejects incomplete output, errors and malformed calls',
    () {
      final invalid = <Map<String, dynamic>>[
        {
          'status': 'incomplete',
          'output': [call()],
        },
        {
          'status': 'failed',
          'output': [call()],
        },
        {
          'error': {'message': 'upstream error'},
          'output': [call()],
        },
        {
          'output': [call(status: 'incomplete')],
        },
        {
          'output': [call(arguments: '{')],
        },
        {
          'output': [call(arguments: '{"prompt":""}')],
        },
        {
          'output': [
            {'type': 'image_generation_call', 'result': 'base64'},
          ],
        },
        {
          'output': [
            {'type': 'message', 'content': 'bad'},
          ],
        },
        {'output': []},
        {'output_text': 'SDK-only convenience field'},
      ];
      for (final response in invalid) {
        expect(
          () => parseAgentReply(response, ApiProtocol.responses),
          throwsFormatException,
          reason: '$response',
        );
      }
    },
  );

  test('Responses keeps unknown tools and repeated calls', () {
    final other = parseAgentReply({
      'output': [call(name: 'other_tool')],
    }, ApiProtocol.responses);
    expect(other.calls.single.name, 'other_tool');
    expect(other.imagePrompt, isNull);

    final repeated = parseAgentReply({
      'output': [call(), call()],
    }, ApiProtocol.responses);
    expect(repeated.calls, hasLength(2));
  });

  test(
    'Responses sends input_image, flat function schema, stateless history and optional parameters',
    () async {
      final root = await Directory.systemTemp.createTemp('imagyn-responses-');
      final file = File('${root.path}/ref.png');
      await file.writeAsBytes([0x89, 0x50, 0x4e, 0x47]);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <Map<String, dynamic>>[];
      final subscription = server.listen((request) async {
        expect(request.uri.path, '/v1/responses');
        expect(request.headers.value('authorization'), 'Bearer test-key');
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': 'completed',
            'output': [call()],
          }),
        );
        await request.response.close();
      });
      final client = StudioApi(
        ServiceConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          agentModel: 'response-model',
          protocol: ApiProtocol.responses,
          vision: true,
        ),
        'test-key',
        '',
        ReferenceStore(file),
      );
      addTearDown(() async {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final ref = Asset(
        id: 'ref',
        path: file.path,
        mime: 'image/png',
        prompt: '',
        createdAt: DateTime(2026),
      );
      final reply = await client.converse(
        [
          const ChatEntry('user', 'old question'),
          const ChatEntry('assistant', 'old answer'),
          const ChatEntry('user', 'edit this'),
        ],
        [ref],
        CancelToken(),
        options: const AgentOptions(
          systemPrompt: 'custom',
          maxOutputTokens: 4096,
          topP: .9,
        ),
      );
      expect(reply.imagePrompt, 'a whale');
      final body = bodies.single;
      expect(body['instructions'], 'custom');
      expect(body['max_output_tokens'], 4096);
      expect(body['top_p'], .9);
      expect(body['store'], false);
      expect(body['parallel_tool_calls'], false);
      expect(body['tools'], [
        for (final tool in agentTools)
          {'type': 'function', ...tool, 'strict': true},
      ]);
      expect(body.containsKey('messages'), false);
      expect(body.containsKey('previous_response_id'), false);
      final input = body['input'] as List;
      expect(input[1], {'role': 'assistant', 'content': 'old answer'});
      expect(input.last['content'], [
        {
          'type': 'input_image',
          'image_url':
              'data:image/png;base64,${base64Encode(await file.readAsBytes())}',
        },
        {'type': 'input_text', 'text': 'edit this'},
      ]);
      await client.converse(
        [const ChatEntry('user', 'hello')],
        [],
        CancelToken(),
        options: const AgentOptions(systemPrompt: ''),
      );
      final minimal = bodies.last;
      for (final key in [
        'instructions',
        'max_output_tokens',
        'temperature',
        'top_p',
        'max_tokens',
        'max_completion_tokens',
      ]) {
        expect(minimal.containsKey(key), false, reason: key);
      }
    },
  );
}
