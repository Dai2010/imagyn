import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http_parser/http_parser.dart';

import 'models.dart';
import 'store.dart';

class AgentReply {
  const AgentReply(this.text, this.imagePrompt);
  final String text;
  final String? imagePrompt;
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
      throw ImageApiException(code, 'HTTP $status · $detail');
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
          result.add(bytes.takeBytes());
        } on DioException catch (error) {
          throw ImageApiException(
            'downloadFailed',
            error.message ?? 'Image download failed',
            outputs: images.every((image) => !image.startsWith('data:'))
                ? images
                : const [],
          );
        } finally {
          download.close(force: true);
        }
      }
    }
    for (final bytes in result) {
      sniffMime(bytes);
    }
    return result;
  }

  Future<AgentReply> converse(
    List<ChatEntry> history,
    List<Asset> refs,
    CancelToken cancel, {
    AgentOptions? options,
  }) async {
    final settings = options ?? config.agentOptions;
    settings.validate(config.protocol);
    history = settings.selectHistory(history);
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
    final system = settings.systemPrompt;
    final messages = <Map<String, dynamic>>[];
    for (var i = 0; i < history.length; i++) {
      final entry = history[i];
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
    final anthropic = config.protocol == ApiProtocol.anthropic;
    final body = config.protocol == ApiProtocol.responses
        ? <String, dynamic>{
            'model': config.agentModel,
            'input': messages,
            if (system.isNotEmpty) 'instructions': system,
            if (settings.maxOutputTokens != null)
              'max_output_tokens': settings.maxOutputTokens,
            if (settings.temperature != null)
              'temperature': settings.temperature,
            if (settings.topP != null) 'top_p': settings.topP,
            'store': false,
            'parallel_tool_calls': false,
            'tools': [
              {'type': 'function', ...imageTool, 'strict': true},
            ],
          }
        : <String, dynamic>{
            'model': config.agentModel,
            'messages': [
              if (!anthropic && system.isNotEmpty)
                {'role': 'system', 'content': system},
              ...messages,
            ],
            if (anthropic && system.isNotEmpty) 'system': system,
            if (anthropic) 'max_tokens': settings.maxOutputTokens ?? 2048,
            if (!anthropic && settings.maxOutputTokens != null)
              'max_completion_tokens': settings.maxOutputTokens,
            if (settings.temperature != null)
              'temperature': settings.temperature,
            if (settings.topP != null) 'top_p': settings.topP,
            'tools': [
              anthropic
                  ? {
                      'name': imageTool['name'],
                      'description': imageTool['description'],
                      'input_schema': imageTool['parameters'],
                    }
                  : {'type': 'function', 'function': imageTool},
            ],
            if (!anthropic) 'parallel_tool_calls': false,
          };
    final response = await dio.postUri(
      config.endpoint(config.protocol.chatPath),
      data: body,
      options: Options(headers: agentHeaders),
      cancelToken: cancel,
    );
    return parseAgentReply(objectResponse(response.data), config.protocol);
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
  final boundedStream = _limitImageResponseBytes(stream);
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

Stream<List<int>> _limitImageResponseBytes(Stream<List<int>> source) async* {
  var received = 0;
  await for (final chunk in source) {
    received += chunk.length;
    if (received > StudioApi.maxImageBytes * 14) {
      throw const FormatException('imageTooLarge');
    }
    yield chunk;
  }
}

AgentReply parseAgentReply(
  Map<String, dynamic> response,
  ApiProtocol protocol,
) {
  final texts = <String>[];
  final prompts = <String>[];
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
        if (item['name'] != 'generate_image') {
          throw const FormatException('unsupportedTool');
        }
        if (item['arguments'] is! String) {
          throw const FormatException('invalidTool');
        }
        Object? arguments;
        try {
          arguments = jsonDecode(item['arguments'] as String);
        } on FormatException {
          throw const FormatException('invalidTool');
        }
        prompts.add(validatePrompt(arguments));
      } else if (item['type'] != 'reasoning') {
        throw const FormatException('unsupportedTool');
      }
    }
  } else if (protocol == ApiProtocol.anthropic) {
    final blocks = response['content'];
    if (blocks is! List) throw const FormatException('invalidResponse');
    for (final block in blocks.whereType<Map>()) {
      if (block['type'] == 'text') texts.add(block['text'] as String);
      if (block['type'] == 'tool_use') {
        // A valid-looking input can still belong to a turn cut off by a token
        // limit. Only dispatch a call once the service says it is ready.
        if (response['stop_reason'] != null &&
            response['stop_reason'] != 'tool_use') {
          throw const FormatException('invalidTool');
        }
        if (block['name'] != 'generate_image') {
          throw const FormatException('unsupportedTool');
        }
        prompts.add(validatePrompt(block['input']));
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
      if (fn['name'] != 'generate_image') {
        throw const FormatException('unsupportedTool');
      }
      if (fn['arguments'] is! String) {
        throw const FormatException('invalidTool');
      }
      Object? arguments;
      try {
        arguments = jsonDecode(fn['arguments'] as String);
      } on FormatException {
        throw const FormatException('invalidTool');
      }
      prompts.add(validatePrompt(arguments));
    }
  }
  if (prompts.length > 1) throw const FormatException('multipleCalls');
  if (texts.isEmpty && prompts.isEmpty) {
    throw const FormatException('invalidResponse');
  }
  return AgentReply(texts.join('\n'), prompts.isEmpty ? null : prompts.single);
}

String validatePrompt(Object? input) {
  if (input is! Map || input['prompt'] is! String) {
    throw const FormatException('invalidTool');
  }
  final prompt = (input['prompt'] as String).trim();
  if (prompt.isEmpty || prompt.length > 32000) {
    throw const FormatException('invalidTool');
  }
  return prompt;
}
