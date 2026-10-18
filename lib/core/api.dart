import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http_parser/http_parser.dart';

import 'models.dart';
import 'store.dart';

class AgentReply {
  const AgentReply(
    this.text,
    this.imagePrompt, {
    this.reasoning = '',
    this.aspectRatio,
    this.calls = const [],
  });
  final String text;
  final String? imagePrompt;

  /// Every call the turn asked for, in order, exactly as it sent them. Empty
  /// when the turn only spoke.
  final List<AgentCall> calls;

  /// The ratio the model asked the image tool to use. Null when it asked for
  /// none (`auto`), in which case the app keeps the ratio chosen in its own
  /// options.
  final String? aspectRatio;

  /// The model's own thinking when the service exposes it: DeepSeek's
  /// `reasoning_content`, an Anthropic `thinking` block, or a Responses
  /// reasoning summary. Empty when the service sends none.
  final String reasoning;
}

/// One piece of a streaming turn. [text] and [reasoning] are the deltas carried
/// by a single update, so usually only one of them is non-empty.
class AgentDelta {
  const AgentDelta({this.text = '', this.reasoning = ''});
  final String text, reasoning;
}

class ImageApiException implements Exception {
  const ImageApiException(this.code, this.detail, {this.outputs = const []});
  final String code, detail;
  final List<String> outputs;
  @override
  String toString() => detail;
}

class StudioApi {
  StudioApi(this.config, this.key, this.imageKey, this.store)
    // No automatic redirects on a request that carries the API key: whatever
    // is on the other end would receive the header. A 3xx surfaces as
    // `redirectBlocked` instead. Downloads use a separate client that sends
    // no credentials and is free to follow a redirect.
    : dio = networkClient(config.proxy, followRedirects: false);
  final ServiceConfig config;
  final String key, imageKey;
  final LocalStore store;
  final Dio dio;
  static const maxImageBytes = 30 * 1024 * 1024;

  /// How far an Agent response may grow before reading it is abandoned. Only
  /// text passes through it, so this guards against a stream that never ends
  /// rather than against a real payload.
  static const maxAgentBytes = 8 * 1024 * 1024;

  /// How many same-origin hops a model list may take before giving up.
  static const maxRedirects = 3;

  Map<String, String> get agentHeaders =>
      config.protocol == ApiProtocol.anthropic
      ? {
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        }
      : {'Authorization': 'Bearer $key', 'content-type': 'application/json'};
  Map<String, String> get imageHeaders => {
    'Authorization': 'Bearer ${imageKey.isEmpty ? key : imageKey}',
  };

  /// Fetches the model list.
  ///
  /// Auto-following redirects is off on this client so the credential cannot be
  /// handed to another host, but a redirect that keeps the request on the same
  /// scheme, host and port is followed by hand — many compatible services
  /// normalise `/models` with one. A connection that never reached the service
  /// is retried, the way ChatBox does; a response, even an error one, is not.
  Future<List<String>> listModels({bool images = false}) async {
    var uri = images
        ? config.imageEndpoint('models')
        : config.endpoint('models');
    final headers = images ? imageHeaders : agentHeaders;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      try {
        final response = await retryNetwork(
          () => dio.getUri(uri, options: Options(headers: headers)),
        );
        return modelIds(response.data);
      } on DioException catch (error) {
        final response = error.response;
        final target = response == null
            ? null
            : sameOriginRedirect(uri, response);
        if (target == null) rethrow;
        uri = target;
      }
    }
    throw const FormatException('redirectBlocked');
  }

  void validateGeneration(
    String prompt,
    List<Asset> refs,
    ImageOptions options,
  ) {
    options.validate();
    if (prompt.trim().isEmpty) throw const FormatException('emptyPrompt');
    if (prompt.length > 32000) throw const FormatException('promptTooLong');
    if (config.imageModel.trim().isEmpty) {
      throw const FormatException('missingImageModel');
    }
    if (refs.length > config.maxReferences) {
      throw const FormatException('referenceLimit');
    }
    if ((imageKey.isEmpty ? key : imageKey).isEmpty) {
      throw const FormatException('missingKey');
    }
    config.imageEndpoint(refs.isEmpty ? 'images/generations' : 'images/edits');
  }

  Future<List<Uint8List>> generate(
    String prompt,
    List<Asset> refs,
    ImageOptions options,
    CancelToken cancel,
  ) async {
    validateGeneration(prompt, refs, options);
    final model = config.imageModel.trim();
    final fields = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      ...options.requestFields(),
      if (config.imageResponseB64) 'response_format': 'b64_json',
      if (config.imageStream && options.count == 1) ...{
        'stream': true,
        'partial_images': 1,
      },
    };
    final Object body;
    if (refs.isEmpty) {
      body = fields;
    } else {
      final files = <MultipartFile>[];
      for (final asset in refs) {
        final file = store.file(asset);
        if (await file.length() > maxImageBytes) {
          throw const FormatException('imageTooLarge');
        }
        files.add(
          await MultipartFile.fromFile(
            file.path,
            contentType: MediaType.parse(asset.mime),
          ),
        );
      }
      body = FormData.fromMap({...fields, 'image[]': files}, ListFormat.multi);
    }
    final response = await dio.postUri<ResponseBody>(
      config.imageEndpoint(
        refs.isEmpty ? 'images/generations' : 'images/edits',
      ),
      data: body,
      options: Options(
        headers: imageHeaders,
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(minutes: 10),
        validateStatus: (_) => true,
      ),
      cancelToken: cancel,
    );
    final stream = response.data!.stream;
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final failure = await _httpFailure(status, stream);
      throw failure;
    }
    final images = await readImageResponse(
      stream,
      eventStream:
          response.headers
              .value('content-type')
              ?.contains('text/event-stream') ==
          true,
    );
    return downloadImages(images, cancel);
  }

  Future<List<Uint8List>> downloadImages(
    List<String> images,
    CancelToken cancel,
  ) async {
    final result = <Uint8List>[];
    for (final output in images) {
      if (output.startsWith('data:')) {
        final payload = output
            .substring(output.indexOf(',') + 1)
            .replaceAll(RegExp(r'\s'), '');
        if (payload.length > maxImageBytes * 4 ~/ 3 + 8) {
          throw const FormatException('imageTooLarge');
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(payload);
        } on FormatException {
          throw const FormatException('invalidImage');
        }
        if (bytes.length > maxImageBytes) {
          throw const FormatException('imageTooLarge');
        }
        sniffMime(bytes);
        result.add(bytes);
      } else {
        final uri = Uri.parse(output);
        if (!['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('invalidImageUrl');
        }
        // This client has no API authorization headers, including across redirects.
        final download = networkClient(config.proxy);
        try {
          final response = await download.getUri<ResponseBody>(
            uri,
            options: Options(responseType: ResponseType.stream),
            cancelToken: cancel,
          );
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.data!.stream) {
            if (bytes.length + chunk.length > maxImageBytes) {
              throw const FormatException('imageTooLarge');
            }
            bytes.add(chunk);
          }
          final image = bytes.takeBytes();
          sniffMime(image);
          result.add(image);
        } on DioException catch (error) {
          throw ImageApiException(
            'downloadFailed',
            error.message ?? 'Image download failed',
            // Retry consumes both URLs and inline images. Preserve the entire
            // batch so a failed URL cannot discard its Base64 siblings.
            outputs: images,
          );
        } on FormatException catch (error) {
          throw ImageApiException(
            error.message,
            error.message,
            outputs: images,
          );
        } finally {
          download.close(force: true);
        }
      }
    }
    return result;
  }

  Future<AgentReply> converse(
    List<ChatEntry> history,
    List<Asset> refs,
    CancelToken cancel, {
    AgentOptions? options,
  }) async {
    final request = await _agentRequest(history, refs, options);
    final response = await dio.postUri(
      config.endpoint(config.protocol.chatPath),
      data: _agentBody(request, stream: false),
      options: Options(headers: agentHeaders),
      cancelToken: cancel,
    );
    return parseAgentReply(objectResponse(response.data), config.protocol);
  }

  /// The streaming form of [converse]: text and reasoning reach [onDelta] as
  /// they arrive.
  ///
  /// The deltas only drive the display. When the stream ends the pieces are
  /// rebuilt into the same shape [parseAgentReply] already validates, so a turn
  /// cut off by a token limit — or a half-written tool call — is rejected by
  /// exactly the rules a non-streaming reply goes through, instead of by a
  /// second set of checks that could drift away from them.
  Future<AgentReply> converseStream(
    List<ChatEntry> history,
    List<Asset> refs,
    CancelToken cancel, {
    AgentOptions? options,
    void Function(AgentDelta delta)? onDelta,
  }) async {
    final request = await _agentRequest(history, refs, options);
    final response = await dio.postUri<ResponseBody>(
      config.endpoint(config.protocol.chatPath),
      data: _agentBody(request, stream: true),
      options: Options(
        headers: agentHeaders,
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(minutes: 10),
        validateStatus: (_) => true,
      ),
      cancelToken: cancel,
    );
    final stream = response.data!.stream;
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final failure = await _httpFailure(status, stream);
      throw failure;
    }
    final bounded = _limitBytes(stream, maxAgentBytes, 'responseTooLarge');
    // A service that ignores `stream: true` still answers with one JSON body;
    // accepting that is better than failing the turn over the transport.
    final eventStream =
        response.headers
            .value('content-type')
            ?.contains('text/event-stream') ==
        true;
    if (!eventStream) {
      final body = StringBuffer();
      await for (final text in utf8.decoder.bind(bounded)) {
        body.write(text);
      }
      return parseAgentReply(objectResponse(body.toString()), config.protocol);
    }
    return switch (config.protocol) {
      ApiProtocol.anthropic => _streamAnthropic(bounded, onDelta),
      ApiProtocol.responses => _streamResponses(bounded, onDelta),
      ApiProtocol.openai => _streamOpenAi(bounded, onDelta),
    };
  }

  /// Reads the beginning of a rejected response so the failure can carry the
  /// service's own words rather than a bare status code.
  Future<ImageApiException> _httpFailure(
    int status,
    Stream<List<int>> stream,
  ) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk.take(4096 - chunks.length));
      if (chunks.length >= 4096) break;
    }
    final detail = utf8.decode(chunks, allowMalformed: true);
    final code = status == 401 || status == 403
        ? 'authError'
        : status == 429
        ? 'rateLimit'
        : status >= 300 && status < 400
        ? 'redirectBlocked'
        : status >= 500
        ? 'unknown'
        : 'serviceError';
    return ImageApiException(code, 'HTTP $status · $detail');
  }

  Future<_AgentRequest> _agentRequest(
    List<ChatEntry> history,
    List<Asset> refs,
    AgentOptions? options,
  ) async {
    final settings = options ?? config.agentOptions;
    settings.validate(config.protocol);
    history = _completeToolCalls(settings.selectHistory(history));
    if (key.isEmpty) throw const FormatException('missingKey');
    if (config.agentModel.trim().isEmpty) {
      throw const FormatException('missingAgentModel');
    }
    if (refs.isNotEmpty && !config.vision) {
      throw const FormatException('visionDisabled');
    }
    if (refs.length > config.maxReferences) {
      throw const FormatException('referenceLimit');
    }
    final contents = <Map<String, dynamic>>[];
    for (final asset in refs) {
      final file = store.file(asset);
      if (await file.length() > maxImageBytes) {
        throw const FormatException('imageTooLarge');
      }
      final data = base64Encode(await file.readAsBytes());
      contents.add(
        config.protocol == ApiProtocol.responses
            ? {
                'type': 'input_image',
                'image_url': 'data:${asset.mime};base64,$data',
              }
            : config.protocol == ApiProtocol.anthropic
            ? {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': asset.mime,
                  'data': data,
                },
              }
            : {
                'type': 'image_url',
                'image_url': {'url': 'data:${asset.mime};base64,$data'},
              },
      );
    }
    final messages = <Map<String, dynamic>>[];
    for (var i = 0; i < history.length; i++) {
      final entry = history[i];
      // A tool result answers a call by id; an assistant turn that called a
      // tool carries the calls themselves. Both have to travel in the shape of
      // whichever protocol is in use, or the next request cannot pair them up.
      if (entry.role == 'tool') {
        messages.add(_toolResult(entry));
        continue;
      }
      if (entry.calls.isNotEmpty) {
        messages.addAll(_assistantCalls(entry));
        continue;
      }
      if (i == history.length - 1 &&
          entry.role == 'user' &&
          contents.isNotEmpty) {
        messages.add({
          'role': 'user',
          'content': [
            ...contents,
            {
              'type': config.protocol == ApiProtocol.responses
                  ? 'input_text'
                  : 'text',
              'text': entry.text,
            },
          ],
        });
      } else {
        messages.add({
          'role': entry.role,
          'content': entry.text.isEmpty ? '[Image result]' : entry.text,
        });
      }
    }
    return _AgentRequest(settings, messages, settings.systemPrompt);
  }

  /// Every assistant turn that called a tool has to be followed by one tool
  /// result per call. A turn cut short — a failed request, a cancel, the
  /// process being killed — can leave that history half written, and an
  /// OpenAI-compatible endpoint then rejects every later request for that
  /// conversation. Filling the holes at send time lets an old session heal
  /// instead of staying unusable.
  List<ChatEntry> _completeToolCalls(List<ChatEntry> history) {
    final repaired = <ChatEntry>[];
    for (var i = 0; i < history.length; i++) {
      final entry = history[i];
      repaired.add(entry);
      if (entry.role != 'assistant' || entry.calls.isEmpty) continue;
      final answered = <String>{};
      var next = i + 1;
      while (next < history.length && history[next].role == 'tool') {
        final callId = history[next].callId;
        if (callId != null) answered.add(callId);
        repaired.add(history[next]);
        next++;
      }
      for (final call in entry.calls) {
        if (answered.contains(call.id)) continue;
        repaired.add(
          ChatEntry(
            'tool',
            'No result was recorded: the turn was interrupted before this '
            'call finished.',
            callId: call.id,
            name: call.name,
          ),
        );
      }
      i = next - 1;
    }
    return repaired;
  }

  Map<String, dynamic> _toolResult(ChatEntry entry) => switch (config.protocol) {
    ApiProtocol.anthropic => {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': entry.callId,
          'content': entry.text,
        },
      ],
    },
    ApiProtocol.responses => {
      'type': 'function_call_output',
      'call_id': entry.callId,
      'output': entry.text,
    },
    ApiProtocol.openai => {
      'role': 'tool',
      'tool_call_id': entry.callId,
      'content': entry.text,
    },
  };

  List<Map<String, dynamic>> _assistantCalls(ChatEntry entry) =>
      switch (config.protocol) {
        ApiProtocol.anthropic => [
          {
            'role': 'assistant',
            'content': [
              if (entry.text.isNotEmpty)
                {'type': 'text', 'text': entry.text},
              for (final call in entry.calls)
                {
                  'type': 'tool_use',
                  'id': call.id,
                  'name': call.name,
                  'input': call.arguments,
                },
            ],
          },
        ],
        ApiProtocol.responses => [
          if (entry.text.isNotEmpty)
            {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': entry.text},
              ],
            },
          for (final call in entry.calls)
            {
              'type': 'function_call',
              'call_id': call.id,
              'name': call.name,
              'arguments': jsonEncode(call.arguments),
            },
        ],
        ApiProtocol.openai => [
          {
            'role': 'assistant',
            'content': entry.text.isEmpty ? null : entry.text,
            'tool_calls': [
              for (final call in entry.calls)
                {
                  'id': call.id,
                  'type': 'function',
                  'function': {
                    'name': call.name,
                    'arguments': jsonEncode(call.arguments),
                  },
                },
            ],
          },
        ],
      };

  Map<String, dynamic> _agentBody(
    _AgentRequest request, {
    required bool stream,
  }) {
    final settings = request.settings;
    final system = request.system;
    final anthropic = config.protocol == ApiProtocol.anthropic;
    return config.protocol == ApiProtocol.responses
        ? <String, dynamic>{
            'model': config.agentModel,
            'input': request.messages,
            if (system.isNotEmpty) 'instructions': system,
            if (settings.maxOutputTokens != null)
              'max_output_tokens': settings.maxOutputTokens,
            if (settings.temperature != null)
              'temperature': settings.temperature,
            if (settings.topP != null) 'top_p': settings.topP,
            'store': false,
            'parallel_tool_calls': false,
            if (stream) 'stream': true,
            'tools': [
              for (final tool in agentTools)
                {'type': 'function', ...tool, 'strict': true},
            ],
          }
        : <String, dynamic>{
            'model': config.agentModel,
            'messages': [
              if (!anthropic && system.isNotEmpty)
                {'role': 'system', 'content': system},
              ...request.messages,
            ],
            if (anthropic && system.isNotEmpty) 'system': system,
            if (anthropic) 'max_tokens': settings.maxOutputTokens ?? 2048,
            if (!anthropic && settings.maxOutputTokens != null)
              'max_completion_tokens': settings.maxOutputTokens,
            if (settings.temperature != null)
              'temperature': settings.temperature,
            if (settings.topP != null) 'top_p': settings.topP,
            if (stream) 'stream': true,
            'tools': [
              for (final tool in agentTools)
                anthropic
                    ? {
                        'name': tool['name'],
                        'description': tool['description'],
                        'input_schema': tool['parameters'],
                      }
                    : {'type': 'function', 'function': tool},
            ],
            if (!anthropic) 'parallel_tool_calls': false,
          };
  }

  /// Chat Completions: `delta.content` for the answer, DeepSeek's
  /// `reasoning_content` (some gateways spell it `reasoning` or `thinking`) for
  /// the thinking, and `delta.tool_calls[].function.arguments` in fragments.
  Future<AgentReply> _streamOpenAi(
    Stream<List<int>> source,
    void Function(AgentDelta delta)? onDelta,
  ) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final refusal = StringBuffer();
    final names = <int, String>{};
    final arguments = <int, StringBuffer>{};
    final order = <int>[];
    String? finish;
    var done = false;
    await for (final event in _sseEvents(source)) {
      if (event.isEmpty) {
        done = true;
        continue;
      }
      final error = event['error'];
      if (error != null) {
        throw ImageApiException(
          'serviceError',
          error is Map ? '${error['message'] ?? error}' : '$error',
        );
      }
      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map) throw const FormatException('invalidResponse');
      if (choice['finish_reason'] is String) {
        finish = choice['finish_reason'] as String;
      }
      // A gateway may send the whole message instead of a delta.
      final delta = choice['delta'] ?? choice['message'];
      if (delta is! Map) continue;
      final piece = _deltaText(delta['content']);
      if (piece.isNotEmpty) {
        text.write(piece);
        onDelta?.call(AgentDelta(text: piece));
      }
      final thought = _deltaText(
        delta['reasoning_content'] ?? delta['reasoning'] ?? delta['thinking'],
      );
      if (thought.isNotEmpty) {
        reasoning.write(thought);
        onDelta?.call(AgentDelta(reasoning: thought));
      }
      final denied = delta['refusal'];
      if (denied is String) refusal.write(denied);
      final calls = delta['tool_calls'];
      if (calls is List) {
        for (final call in calls.whereType<Map>()) {
          final index = (call['index'] as num?)?.toInt() ?? 0;
          if (!names.containsKey(index) && !arguments.containsKey(index)) {
            order.add(index);
          }
          final fn = call['function'];
          if (fn is! Map) continue;
          final name = fn['name'];
          if (name is String && name.isNotEmpty) names[index] = name;
          final args = fn['arguments'];
          if (args is String) (arguments[index] ??= StringBuffer()).write(args);
        }
      }
    }
    // Neither a finish reason nor the `[DONE]` marker means the connection died
    // mid-turn: the call accumulated so far is one the service never confirmed,
    // and acting on it would start a generation nobody asked to be billed for.
    if (finish == null && !done) {
      throw const FormatException('incompleteStream');
    }
    return parseAgentReply({
      'choices': [
        {
          'finish_reason': finish,
          'message': {
            'content': text.isEmpty ? null : text.toString(),
            // The thinking is stored with the message, so it has to survive the
            // reassembly too — otherwise it shows while streaming and then
            // vanishes from the finished bubble.
            if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
            if (refusal.isNotEmpty) 'refusal': refusal.toString(),
            if (order.isNotEmpty)
              'tool_calls': [
                for (final index in order)
                  {
                    'function': {
                      'name': names[index] ?? '',
                      'arguments': (arguments[index] ?? StringBuffer())
                          .toString(),
                    },
                  },
              ],
          },
        },
      ],
    }, ApiProtocol.openai);
  }

  /// Anthropic Messages: `content_block_delta` carries `text_delta`,
  /// `thinking_delta` and `input_json_delta`; the stop reason only arrives with
  /// `message_delta` at the end.
  Future<AgentReply> _streamAnthropic(
    Stream<List<int>> source,
    void Function(AgentDelta delta)? onDelta,
  ) async {
    final blocks = <int, Map<String, dynamic>>{};
    final partials = <int, StringBuffer>{};
    String? stop;
    var stopped = false;
    await for (final event in _sseEvents(source)) {
      final type = event['type'];
      if (type == 'message_stop') {
        stopped = true;
        continue;
      }
      if (type == 'error') {
        final error = event['error'];
        throw ImageApiException(
          'serviceError',
          error is Map ? '${error['message'] ?? error}' : '${error ?? type}',
        );
      }
      if (type == 'message_delta') {
        final delta = event['delta'];
        if (delta is Map && delta['stop_reason'] is String) {
          stop = delta['stop_reason'] as String;
        }
        continue;
      }
      if (type == 'content_block_start') {
        final block = event['content_block'];
        if (block is! Map) continue;
        final index = (event['index'] as num?)?.toInt() ?? 0;
        blocks[index] = {
          'type': block['type'],
          if (block['name'] is String) 'name': block['name'],
          if (block['text'] is String) 'text': block['text'],
          if (block['thinking'] is String) 'thinking': block['thinking'],
        };
        continue;
      }
      if (type != 'content_block_delta') continue;
      final delta = event['delta'];
      if (delta is! Map) continue;
      final index = (event['index'] as num?)?.toInt() ?? 0;
      final kind = delta['type'];
      final block = blocks[index] ??= {
        'type': kind == 'thinking_delta'
            ? 'thinking'
            : kind == 'input_json_delta'
            ? 'tool_use'
            : 'text',
      };
      if (kind == 'text_delta' && delta['text'] is String) {
        final piece = delta['text'] as String;
        block['text'] = '${block['text'] ?? ''}$piece';
        onDelta?.call(AgentDelta(text: piece));
      } else if (kind == 'thinking_delta' && delta['thinking'] is String) {
        final piece = delta['thinking'] as String;
        block['thinking'] = '${block['thinking'] ?? ''}$piece';
        onDelta?.call(AgentDelta(reasoning: piece));
      } else if (kind == 'input_json_delta' && delta['partial_json'] is String) {
        (partials[index] ??= StringBuffer()).write(
          delta['partial_json'] as String,
        );
      }
    }
    // `message_stop`, or at least a stop reason, is the only proof that the turn
    // finished rather than the connection dropping.
    if (!stopped && stop == null) {
      throw const FormatException('incompleteStream');
    }
    final indexes = blocks.keys.toList()..sort();
    final content = <Map<String, dynamic>>[];
    for (final index in indexes) {
      final block = Map<String, dynamic>.of(blocks[index]!);
      if (block['type'] == 'tool_use') {
        final partial = partials[index]?.toString() ?? '';
        block['input'] = _decodedJson(partial);
      }
      content.add(block);
    }
    return parseAgentReply({
      'stop_reason': stop,
      'content': content,
    }, ApiProtocol.anthropic);
  }

  /// Responses: the text arrives as `response.output_text.delta` events and the
  /// finished turn as a single `response.completed` object. That object is what
  /// states the function call and the turn's own status, so the deltas are only
  /// there for the display.
  Future<AgentReply> _streamResponses(
    Stream<List<int>> source,
    void Function(AgentDelta delta)? onDelta,
  ) async {
    Map<String, dynamic>? completed;
    String? failure;
    await for (final event in _sseEvents(source)) {
      final type = event['type'];
      if (type == 'response.completed') {
        final response = event['response'];
        if (response is Map<String, dynamic>) completed = response;
        continue;
      }
      if (type == 'response.failed' ||
          type == 'response.error' ||
          type == 'error') {
        final error = event['error'];
        failure = error is Map ? '${error['message'] ?? error}' : '$type';
        continue;
      }
      if (type == 'response.output_text.delta' && event['delta'] is String) {
        onDelta?.call(AgentDelta(text: event['delta'] as String));
        continue;
      }
      if (type == 'response.reasoning_summary_text.delta' &&
          event['delta'] is String) {
        onDelta?.call(AgentDelta(reasoning: event['delta'] as String));
      }
    }
    if (failure != null) throw ImageApiException('serviceError', failure);
    // Without the finished response nothing states what the turn did, so the
    // stream was cut off rather than answered.
    if (completed == null) throw const FormatException('incompleteStream');
    return parseAgentReply(completed, ApiProtocol.responses);
  }

  void close() => dio.close(force: true);
}

Dio networkClient(String proxy, {bool followRedirects = true}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 5),
      sendTimeout: const Duration(minutes: 2),
      followRedirects: followRedirects,
    ),
  );
  if (proxy.trim().isNotEmpty) {
    final uri = Uri.parse(proxy);
    if (uri.scheme != 'http' ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('invalidProxy');
    }
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()..findProxy = (_) => 'PROXY ${uri.host}:${uri.port}',
    );
  }
  return dio;
}

/// Retries a request only when it never reached the service, the way ChatBox
/// does: a response, even an error one, means the service answered and retrying
/// would only repeat the same answer.
Future<T> retryNetwork<T>(
  Future<T> Function() request, {
  int attempts = 3,
}) async {
  DioException? failure;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      return await request();
    } on DioException catch (error) {
      if (error.response != null) rethrow;
      failure = error;
      if (attempt < attempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }
  throw failure!;
}

/// The redirect target, but only when following it keeps the request on the same
/// scheme, host and port. Anything else would hand the credential to another
/// host, which is exactly why this client does not follow redirects by itself.
Uri? sameOriginRedirect(Uri from, Response<dynamic> response) {
  final status = response.statusCode ?? 0;
  if (status < 300 || status >= 400) return null;
  final location = response.headers.value('location');
  if (location == null) return null;
  final target = from.resolve(location);
  if (target.scheme != from.scheme || target.host != from.host) return null;
  return _portOf(target) == _portOf(from) ? target : null;
}

int _portOf(Uri uri) =>
    uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

/// The ids out of a `{"data": [{"id": …}]}` model list.
List<String> modelIds(Object? body) {
  final data = objectResponse(body)['data'];
  if (data is! List) throw const FormatException('invalidResponse');
  return data.whereType<Map>().map((e) => e['id']).whereType<String>().toList()
    ..sort();
}

Map<String, dynamic> objectResponse(Object? value) {
  if (value is String) value = jsonDecode(value);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalidResponse');
  }
  return value;
}

List<String> imageOutputs(Map<String, dynamic> response) {
  if (response['error'] != null) {
    final error = response['error'];
    throw ImageApiException(
      'serviceError',
      error is Map ? '${error['message'] ?? error}' : '$error',
    );
  }
  final data = response['data'];
  if (data is! List || data.isEmpty) throw const FormatException('noImage');
  return data.map((item) {
    if (item is! Map) throw const FormatException('invalidResponse');
    final b64 = item['b64_json'];
    if (b64 is String && b64.isNotEmpty) {
      return b64.startsWith('data:') ? b64 : 'data:image/*;base64,$b64';
    }
    final url = item['url'];
    if (url is String && url.isNotEmpty) return url;
    throw const FormatException('noImage');
  }).toList();
}

/// Reads JSON or SSE without treating a preview frame as a finished image.
Future<List<String>> readImageResponse(
  Stream<List<int>> stream, {
  required bool eventStream,
}) async {
  // Bound source bytes before decoding or splitting lines: an SSE peer can
  // otherwise grow LineSplitter's buffer indefinitely without a newline.
  final boundedStream = _limitBytes(
    stream,
    StudioApi.maxImageBytes * 14,
    'imageTooLarge',
  );
  if (!eventStream) {
    final body = StringBuffer();
    await for (final text in utf8.decoder.bind(boundedStream)) {
      body.write(text);
    }
    return imageOutputs(objectResponse(body.toString()));
  }
  final completed = <String>[];
  List<String>? finalResult;
  final data = <String>[];
  void dispatch() {
    if (data.isEmpty) return;
    final payload = data.join('\n');
    data.clear();
    if (payload.trim() == '[DONE]') return;
    final event = objectResponse(payload);
    final type = event['type'] as String? ?? '';
    if (event['error'] != null || type == 'error' || type.endsWith('.failed')) {
      final error = event['error'];
      throw ImageApiException(
        'serviceError',
        error is Map
            ? '${error['message'] ?? error}'
            : '${error ?? event['message'] ?? type}',
      );
    }
    if (type.endsWith('.partial_image')) return;
    if (event['data'] is List) {
      finalResult = imageOutputs(event);
    } else if (type == 'image_generation.completed' ||
        type == 'image_edit.completed') {
      completed.addAll(
        imageOutputs({
          'data': [event],
        }),
      );
    }
  }

  await for (final line
      in utf8.decoder.bind(boundedStream).transform(const LineSplitter())) {
    if (line.isEmpty) {
      dispatch();
    } else if (line.startsWith('data:')) {
      final value = line.substring(5).replaceFirst(RegExp(r'^ '), '');
      data.add(value);
    }
  }
  dispatch();
  final result = finalResult ?? completed;
  if (result.isEmpty) throw const FormatException('incompleteImageStream');
  return result;
}

Stream<List<int>> _limitBytes(
  Stream<List<int>> source,
  int limit,
  String code,
) async* {
  var received = 0;
  await for (final chunk in source) {
    received += chunk.length;
    if (received > limit) throw FormatException(code);
    yield chunk;
  }
}

AgentReply parseAgentReply(
  Map<String, dynamic> response,
  ApiProtocol protocol,
) {
  final texts = <String>[];
  final calls = <AgentCall>[];
  final reasons = <String>[];
  if (protocol == ApiProtocol.responses) {
    if (response['error'] != null ||
        (response['status'] != null && response['status'] != 'completed')) {
      throw const FormatException('invalidResponse');
    }
    final output = response['output'];
    if (output is! List) throw const FormatException('invalidResponse');
    for (final item in output) {
      if (item is! Map) throw const FormatException('invalidResponse');
      if (item['type'] == 'message') {
        if (item['status'] != null && item['status'] != 'completed') {
          throw const FormatException('invalidResponse');
        }
        final content = item['content'];
        if (content is! List) throw const FormatException('invalidResponse');
        for (final block in content) {
          if (block is! Map) throw const FormatException('invalidResponse');
          if (block['type'] == 'output_text') {
            if (block['text'] is! String) {
              throw const FormatException('invalidResponse');
            }
            if ((block['text'] as String).isNotEmpty) {
              texts.add(block['text'] as String);
            }
          } else if (block['type'] == 'refusal' && block['refusal'] is String) {
            texts.add(block['refusal'] as String);
          }
        }
      } else if (item['type'] == 'function_call') {
        if (item['status'] != null && item['status'] != 'completed') {
          throw const FormatException('invalidTool');
        }
        final id = item['call_id'] ?? item['id'];
        if (item['name'] is! String || item['arguments'] is! String) {
          throw const FormatException('invalidTool');
        }
        Object? arguments;
        try {
          arguments = jsonDecode(item['arguments'] as String);
        } on FormatException {
          throw const FormatException('invalidTool');
        }
        if (arguments is! Map) throw const FormatException('invalidTool');
        calls.add(
          AgentCall(
            // Some gateways drop the id. The loop only needs a stable handle
            // to pair a result with its call, so a local one is enough.
            id is String && id.isNotEmpty ? id : 'call_${calls.length}',
            item['name'] as String,
            Map<String, dynamic>.from(arguments),
          ),
        );
      } else if (item['type'] == 'reasoning') {
        // A reasoning summary is display material, never an instruction.
        final summary = item['summary'];
        if (summary is List) {
          for (final part in summary.whereType<Map>()) {
            final thought = part['text'];
            if (thought is String && thought.isNotEmpty) reasons.add(thought);
          }
        }
      } else {
        throw const FormatException('unsupportedTool');
      }
    }
  } else if (protocol == ApiProtocol.anthropic) {
    final blocks = response['content'];
    if (blocks is! List) throw const FormatException('invalidResponse');
    for (final block in blocks.whereType<Map>()) {
      if (block['type'] == 'text') texts.add(block['text'] as String);
      if (block['type'] == 'thinking') {
        final thought = block['thinking'];
        if (thought is String && thought.isNotEmpty) reasons.add(thought);
      }
      if (block['type'] == 'tool_use') {
        // A valid-looking input can still belong to a turn cut off by a token
        // limit. Only dispatch a call once the service says it is ready.
        if (response['stop_reason'] != null &&
            response['stop_reason'] != 'tool_use') {
          throw const FormatException('invalidTool');
        }
        if (block['name'] is! String || block['input'] is! Map) {
          throw const FormatException('invalidTool');
        }
        final id = block['id'];
        calls.add(
          AgentCall(
            id is String && id.isNotEmpty ? id : 'call_${calls.length}',
            block['name'] as String,
            Map<String, dynamic>.from(block['input'] as Map),
          ),
        );
      }
    }
  } else {
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('invalidResponse');
    }
    final choice = choices.first;
    if (choice is! Map || choice['message'] is! Map) {
      throw const FormatException('invalidResponse');
    }
    final message = choice['message'] as Map;
    if (message['content'] is String) texts.add(message['content'] as String);
    final thought = message['reasoning_content'] ?? message['reasoning'];
    if (thought is String && thought.isNotEmpty) reasons.add(thought);
    final refusal = message['refusal'];
    if (refusal != null && refusal is! String) {
      throw const FormatException('invalidResponse');
    }
    final refused = refusal is String && refusal.isNotEmpty;
    if (refused) texts.add(refusal);
    final tools = message['tool_calls'] ?? [];
    if (tools is! List) throw const FormatException('invalidTool');
    if (tools.isNotEmpty &&
        (refused ||
            (choice['finish_reason'] != null &&
                choice['finish_reason'] != 'tool_calls'))) {
      throw const FormatException('invalidTool');
    }
    for (final tool in tools) {
      if (tool is! Map || tool['function'] is! Map) {
        throw const FormatException('invalidTool');
      }
      final fn = tool['function'] as Map;
      if (fn['name'] is! String || fn['arguments'] is! String) {
        throw const FormatException('invalidTool');
      }
      Object? arguments;
      try {
        arguments = jsonDecode(fn['arguments'] as String);
      } on FormatException {
        throw const FormatException('invalidTool');
      }
      if (arguments is! Map) throw const FormatException('invalidTool');
      final id = tool['id'];
      calls.add(
        AgentCall(
          id is String && id.isNotEmpty ? id : 'call_${calls.length}',
          fn['name'] as String,
          Map<String, dynamic>.from(arguments),
        ),
      );
    }
  }
  if (texts.isEmpty && calls.isEmpty) {
    throw const FormatException('invalidResponse');
  }
  // The image prompt is still derived here so a single-call turn keeps working
  // until the executor takes over. Every image call is validated, so a bad
  // ratio fails the turn instead of being silently dropped.
  ToolCall? image;
  for (final call in calls) {
    if (call.name != imageTool['name']) continue;
    final parsed = validateToolCall(call.arguments);
    image ??= parsed;
  }
  return AgentReply(
    texts.join('\n'),
    image?.prompt,
    reasoning: reasons.join('\n'),
    aspectRatio: image?.aspectRatio,
    calls: calls,
  );
}

/// A validated `generate_image` call: the prompt the image service receives and
/// the ratio the model chose for it, if any.
typedef ToolCall = ({String prompt, String? aspectRatio});

ToolCall validateToolCall(Object? input) {
  if (input is! Map || input['prompt'] is! String) {
    throw const FormatException('invalidTool');
  }
  final prompt = (input['prompt'] as String).trim();
  if (prompt.isEmpty || prompt.length > 32000) {
    throw const FormatException('invalidTool');
  }
  final ratio = input['aspect_ratio'];
  if (ratio == null) return (prompt: prompt, aspectRatio: null);
  if (ratio is! String || (ratio != 'auto' && !sizePresets.containsKey(ratio))) {
    throw const FormatException('invalidTool');
  }
  return (prompt: prompt, aspectRatio: ratio == 'auto' ? null : ratio);
}

/// The parts of an Agent turn that are the same whether it is streamed or not:
/// the validated options, the assembled messages and the system prompt.
class _AgentRequest {
  const _AgentRequest(this.settings, this.messages, this.system);
  final AgentOptions settings;
  final List<Map<String, dynamic>> messages;
  final String system;
}

/// The JSON object of each `data:` frame in a server-sent event stream. Frames
/// are separated by a blank line, so `event:` names, comments and keep-alives
/// are skipped without needing to understand them.
///
/// An empty map stands for the `[DONE]` marker, so a caller can tell a stream
/// the service finished from one that was cut off — from the outside they look
/// the same.
Stream<Map<String, dynamic>> _sseEvents(Stream<List<int>> source) async* {
  final data = <String>[];
  await for (final line
      in utf8.decoder.bind(source).transform(const LineSplitter())) {
    if (line.isNotEmpty) {
      if (line.startsWith('data:')) {
        data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
      }
      continue;
    }
    final event = _takeFrame(data);
    if (event != null) yield event;
  }
  // A stream that ends without its closing blank line still carries a frame.
  final event = _takeFrame(data);
  if (event != null) yield event;
}

/// Takes the buffered frame, or null when it held nothing usable. An empty map
/// means the peer sent `[DONE]`.
Map<String, dynamic>? _takeFrame(List<String> data) {
  final payload = data.join('\n').trim();
  data.clear();
  if (payload.isEmpty) return null;
  if (payload == '[DONE]') return const {};
  try {
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Flattens the shapes a gateway may use for one piece of text: a plain string,
/// or the array of content blocks an Anthropic-shaped service sends through an
/// OpenAI-shaped endpoint.
String _deltaText(Object? value) {
  if (value is String) return value;
  if (value is List) {
    final buffer = StringBuffer();
    for (final block in value.whereType<Map>()) {
      final text = block['text'];
      if (text is String) buffer.write(text);
    }
    return buffer.toString();
  }
  return '';
}

/// The decoded tool input, or null when the fragments never formed valid JSON —
/// which is what a turn cut off in the middle of a call looks like.
Object? _decodedJson(String text) {
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
