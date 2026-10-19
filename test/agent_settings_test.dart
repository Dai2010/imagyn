import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/api.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';

import 'support/memory_store.dart';

void main() {
  test(
    'old settings retain built-in prompt; custom and empty prompts survive JSON',
    () {
      expect(
        ServiceConfig.fromJson({}).agentOptions.systemPrompt,
        defaultAgentPrompt,
      );
      for (final prompt in ['', '只用中文讨论构图。']) {
        final config = ServiceConfig(
          agentModel: 'a',
          agentProfiles: {
            'a': AgentOptions(
              systemPrompt: prompt,
              contextMessages: 6,
              maxOutputTokens: 8192,
              topP: .8,
            ),
          },
        );
        final value = ServiceConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
        );
        expect(value.agentOptions.systemPrompt, prompt);
        expect(value.agentOptions.contextMessages, 6);
        expect(value.agentOptions.maxOutputTokens, 8192);
        expect(value.agentOptions.topP, .8);
        expect(
          value.copyWith(agentModel: 'b').agentOptions.systemPrompt,
          defaultAgentPrompt,
        );
      }
    },
  );

  test(
    'history selection keeps newest user turn without mutating local history',
    () {
      const history = [
        ChatEntry('user', 'old'),
        ChatEntry('assistant', 'old reply'),
        ChatEntry('user', 'recent'),
        ChatEntry('assistant', 'recent reply'),
        ChatEntry('user', 'current'),
      ];
      expect(
        const AgentOptions(
          contextMessages: 3,
        ).selectHistory(history).map((e) => e.text),
        ['recent', 'recent reply', 'current'],
      );
      expect(
        const AgentOptions(
          contextMessages: 2,
        ).selectHistory(history).map((e) => e.text),
        ['current'],
      );
      expect(const AgentOptions().selectHistory(history), history);
      expect(history.length, 5);
      expect(
        () => const AgentOptions(
          temperature: double.nan,
        ).validate(ApiProtocol.openai),
        throwsFormatException,
      );
      expect(
        () => const AgentOptions(
          temperature: .5,
          topP: .8,
        ).validate(ApiProtocol.anthropic),
        throwsFormatException,
      );
    },
  );

  test(
    'model and per-model options persist, history survives, new conversations inherit defaults',
    () async {
      final store = MemoryStore();
      final studio = Studio(store);
      await studio.initialize();
      final firstSession = studio.session;
      await store.addMessage(
        firstSession,
        const ChatEntry('user', 'keep history'),
      );
      await studio.refresh();
      await studio.switchModel('agent-b', agent: true);
      await studio.setAgentOptions(
        const AgentOptions(systemPrompt: 'custom', contextMessages: 5),
      );
      await studio.switchModel('image-b', agent: false);
      await studio.switchModel('agent-a', agent: true);
      expect(studio.agentOptions.systemPrompt, defaultAgentPrompt);
      await studio.switchModel('agent-b', agent: true);
      expect(studio.agentOptions.systemPrompt, 'custom');
      final restored = Studio(store);
      await restored.initialize();
      expect(restored.session, firstSession);
      expect(restored.activeConfig.agentModel, 'agent-b');
      expect(restored.activeConfig.imageModel, 'image-b');
      expect(restored.agentOptions.contextMessages, 5);
      expect(restored.chat.single.text, 'keep history');
      await restored.newConversation();
      expect(restored.activeConfig.agentModel, 'agent-a');
      expect(restored.activeConfig.imageModel, 'image-a');
      expect(restored.agentOptions.systemPrompt, defaultAgentPrompt);
      await restored.switchConversation(firstSession);
      expect(restored.agentOptions.systemPrompt, 'custom');
      expect(restored.chat.single.text, 'keep history');
      restored.busy = true;
      await restored.switchModel('blocked', agent: true);
      expect(restored.activeConfig.agentModel, 'agent-b');
      restored.dispose();
      studio.dispose();
    },
  );

  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol sends selected model, custom prompt and output/context parameters',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final received = Completer<Map<String, dynamic>>();
        final subscription = server.listen((request) async {
          received.complete(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          expect(request.uri.path, '/v1/${protocol.chatPath}');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              protocol == ApiProtocol.responses
                  ? {
                      'status': 'completed',
                      'output': [
                        {
                          'type': 'message',
                          'content': [
                            {'type': 'output_text', 'text': 'OK'},
                          ],
                        },
                      ],
                    }
                  : protocol == ApiProtocol.openai
                  ? {
                      'choices': [
                        {
                          'message': {'content': 'OK'},
                        },
                      ],
                    }
                  : {
                      'content': [
                        {'type': 'text', 'text': 'OK'},
                      ],
                    },
            ),
          );
          await request.response.close();
        });
        final store = MemoryStore()
          ..savedConfig = ServiceConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            protocol: protocol,
          );
        final studio = Studio(store);
        await studio.initialize();
        await studio.switchModel('selected-model', agent: true);
        await studio.setAgentOptions(
          const AgentOptions(
            systemPrompt: 'custom instruction',
            contextMessages: 1,
            maxOutputTokens: 4096,
            temperature: .4,
          ),
        );
        await store.addMessage(studio.session, const ChatEntry('user', 'old'));
        await store.addMessage(
          studio.session,
          const ChatEntry('assistant', 'old answer'),
        );
        await studio.submit('latest', true, const ImageOptions());
        expect(studio.error, isNull);
        final body = await received.future;
        expect(body['model'], 'selected-model');
        expect(body['temperature'], .4);
        expect(body.containsKey('top_p'), isFalse);
        final messages =
            body[protocol == ApiProtocol.responses ? 'input' : 'messages']
                as List;
        expect(messages.last['content'], 'latest');
        expect(messages.any((e) => e['content'] == 'old'), isFalse);
        if (protocol == ApiProtocol.responses) {
          expect(body['instructions'], 'custom instruction');
          expect(body['max_output_tokens'], 4096);
          expect(body['store'], false);
          expect(body.containsKey('messages'), false);
          expect(messages.length, 1);
        } else if (protocol == ApiProtocol.openai) {
          expect(messages.first, {
            'role': 'system',
            'content': 'custom instruction',
          });
          expect(body['max_completion_tokens'], 4096);
          expect(body.containsKey('system'), isFalse);
        } else {
          expect(body['system'], 'custom instruction');
          expect(body['max_tokens'], 4096);
          expect(messages.length, 1);
        }
        expect(studio.chat.length, 4);
        expect(studio.chat.last.model, 'selected-model');
        studio.dispose();
        await subscription.cancel();
        await server.close(force: true);
      },
    );
  }

  test('empty system prompt and unset OpenAI parameters are omitted', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      received.complete(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"choices":[{"message":{"content":"OK"}}]}');
      await request.response.close();
    });
    final client = StudioApi(
      ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'a',
      ),
      'key',
      '',
      MemoryStore(),
    );
    await client.converse(
      [const ChatEntry('user', 'hello')],
      [],
      CancelToken(),
      options: const AgentOptions(systemPrompt: ''),
    );
    final body = await received.future;
    expect(body['messages'], [
      {'role': 'user', 'content': 'hello'},
    ]);
    for (final key in [
      'system',
      'max_tokens',
      'max_completion_tokens',
      'temperature',
      'top_p',
    ]) {
      expect(body.containsKey(key), isFalse, reason: key);
    }
    client.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  test('a call without a result is filled before the request is sent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      received.complete(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"choices":[{"message":{"content":"OK"}}]}');
      await request.response.close();
    });
    final client = StudioApi(
      ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'a',
      ),
      'key',
      '',
      MemoryStore(),
    );
    await client.converse(
      [
        const ChatEntry(
          'assistant',
          '',
          calls: [
            AgentCall('call-1', 'generate_image', {
              'prompt': 'a fox',
              'aspect_ratio': 'auto',
            }),
          ],
        ),
        const ChatEntry('user', 'next'),
      ],
      [],
      CancelToken(),
    );
    final messages = (await received.future)['messages'] as List;
    final assistant = messages.indexWhere(
      (entry) => (entry as Map)['role'] == 'assistant',
    );
    expect(messages[assistant + 1], {
      'role': 'tool',
      'tool_call_id': 'call-1',
      'content':
          'No result was recorded: the turn was interrupted before this call finished.',
    });
    expect(messages[assistant + 2], {'role': 'user', 'content': 'next'});
    client.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  test('OpenAI history sends back every assistant reasoning_content', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      received.complete(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"choices":[{"message":{"content":"OK"}}]}');
      await request.response.close();
    });
    final client = StudioApi(
      ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'deepseek-reasoner',
      ),
      'key',
      '',
      MemoryStore(),
    );
    await client.converse(
      [
        const ChatEntry('user', 'hello'),
        const ChatEntry(
          'assistant',
          'hi',
          reasoning: 'A short greeting is enough.',
        ),
        const ChatEntry('user', 'draw a fox'),
        const ChatEntry(
          'assistant',
          '',
          reasoning: 'The user wants an image, so call generate_image.',
          calls: [
            AgentCall('call-1', 'generate_image', {'prompt': 'a fox'}),
          ],
        ),
        const ChatEntry('tool', 'a fox', callId: 'call-1'),
        const ChatEntry('assistant', 'one more'),
        const ChatEntry('user', 'thanks'),
      ],
      [],
      CancelToken(),
    );
    final messages = (await received.future)['messages'] as List;
    // DeepSeek rejects a request that carries tools unless every earlier
    // assistant turn brings its reasoning_content along, tool calls included.
    expect(messages[2], {
      'role': 'assistant',
      'reasoning_content': 'A short greeting is enough.',
      'content': 'hi',
    });
    expect(
      messages[4]['reasoning_content'],
      'The user wants an image, so call generate_image.',
    );
    expect(messages[5], {
      'role': 'tool',
      'tool_call_id': 'call-1',
      'content': 'a fox',
    });
    // An assistant turn with no thinking still has to carry the key.
    expect(messages[6], {
      'role': 'assistant',
      'reasoning_content': '',
      'content': 'one more',
    });
    client.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  test('reasoning_content stays off other OpenAI-compatible models', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      received.complete(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"choices":[{"message":{"content":"OK"}}]}');
      await request.response.close();
    });
    final client = StudioApi(
      ServiceConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        agentModel: 'gpt-4o',
      ),
      'key',
      '',
      MemoryStore(),
    );
    await client.converse(
      [
        const ChatEntry('user', 'hello'),
        const ChatEntry('assistant', 'hi', reasoning: 'A short greeting.'),
        const ChatEntry('user', 'again'),
      ],
      [],
      CancelToken(),
    );
    final messages = (await received.future)['messages'] as List;
    expect(messages[2], {'role': 'assistant', 'content': 'hi'});
    client.close();
    await subscription.cancel();
    await server.close(force: true);
  });
}
