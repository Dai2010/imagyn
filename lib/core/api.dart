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

  Map<String, String> get agentHeaders => config.protocol == ApiProtocol.anthropic
    ? {'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json'}
    : {'Authorization': 'Bearer $key', 'content-type': 'application/json'};
  Map<String, String> get imageHeaders => {'Authorization': 'Bearer ${imageKey.isEmpty ? key : imageKey}'};

  /// Fetches the model list.
  ///
  /// Auto-following redirects is off on this client so the credential cannot be
  /// handed to another host, but a redirect that keeps the request on the same
  /// scheme, host and port is followed by hand — many compatible services
  /// normalise `/models` with one. A connection that never reached the service
  /// is retried, the way ChatBox does; a response, even an error one, is not.
  Future<List<String>> listModels({bool images = false}) async {
    var uri = images ? config.imageEndpoint('models') : config.endpoint('models');
    final headers = images ? imageHeaders : agentHeaders;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      try {
        final response = await retryNetwork(() => dio.getUri(uri, options: Options(headers: headers)));
        return modelIds(response.data);
      } on DioException catch (error) {
        final response = error.response;
        final target = response == null ? null : sameOriginRedirect(uri, response);
        if (target == null) rethrow;
        uri = target;
      }
    }
    throw const FormatException('redirectBlocked');
  }

  Future<List<Uint8List>> generate(String prompt, List<Asset> refs, String size,
      CancelToken cancel) async {
    if (config.imageModel.trim().isEmpty) throw const FormatException('missingImageModel');
    if (refs.length > config.maxReferences) throw const FormatException('referenceLimit');
    if ((imageKey.isEmpty ? key : imageKey).isEmpty) throw const FormatException('missingKey');
    final model = config.imageModel.trim();
    final Object body;
    if (refs.isEmpty) {
      body = {'model': model, 'prompt': prompt, 'n': 1, 'size': size};
    } else {
      final files = <MultipartFile>[];
      for (final asset in refs) {
        final file = store.file(asset);
        if (await file.length() > maxImageBytes) throw const FormatException('imageTooLarge');
        files.add(await MultipartFile.fromFile(file.path,
          contentType: MediaType.parse(asset.mime)));
      }
      body = FormData.fromMap({'model': model, 'prompt': prompt, 'n': '1',
        'size': size, 'image': files}, ListFormat.multiCompatible);
    }
    final response = await dio.postUri(config.imageEndpoint(
      refs.isEmpty ? 'images/generations' : 'images/edits'), data: body,
      options: Options(headers: imageHeaders), cancelToken: cancel);
    final images = imageOutputs(objectResponse(response.data));
    final result = <Uint8List>[];
    for (final output in images) {
      if (output.startsWith('data:')) {
        final payload = output.substring(output.indexOf(',') + 1);
        if (payload.length > maxImageBytes * 4 ~/ 3 + 8) throw const FormatException('imageTooLarge');
        result.add(base64Decode(payload));
      } else {
        final uri = Uri.parse(output);
        if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
          throw const FormatException('invalidImageUrl');
        }
        // This client has no API authorization headers, including across redirects.
        final download = networkClient(config.proxy);
        try {
          final response = await download.getUri<ResponseBody>(uri,
            options: Options(responseType: ResponseType.stream), cancelToken: cancel);
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.data!.stream) {
            if (bytes.length + chunk.length > maxImageBytes) throw const FormatException('imageTooLarge');
            bytes.add(chunk);
          }
          result.add(bytes.takeBytes());
        } finally {
          download.close(force: true);
        }
      }
    }
    for (final bytes in result) { sniffMime(bytes); }
    return result;
  }

  Future<AgentReply> converse(List<ChatEntry> history, List<Asset> refs,
      CancelToken cancel) async {
    if (key.isEmpty) throw const FormatException('missingKey');
    if (config.agentModel.trim().isEmpty) throw const FormatException('missingAgentModel');
    if (refs.isNotEmpty && !config.vision) throw const FormatException('visionDisabled');
    if (refs.length > config.maxReferences) throw const FormatException('referenceLimit');
    final contents = <Map<String, dynamic>>[];
    for (final asset in refs) {
      final file = store.file(asset);
      if (await file.length() > maxImageBytes) throw const FormatException('imageTooLarge');
      final data = base64Encode(await file.readAsBytes());
      contents.add(config.protocol == ApiProtocol.anthropic
        ? {'type': 'image', 'source': {'type': 'base64', 'media_type': asset.mime, 'data': data}}
        : {'type': 'image_url', 'image_url': {'url': 'data:${asset.mime};base64,$data'}});
    }
    const system = 'You are Imagyn, an image creation assistant. Reply in the user language. '
      'Use generate_image only for an explicit request to create or modify an image. '
      'Never claim an image was generated yourself. For discussions reply in text. '
      'Only one generation per turn. Reference images are ordered and supplied to '
      'the image tool by the application. For an edit preserve user constraints. '
      'If the target is unclear, ask. Tool prompts should be self-contained.';
    final messages = <Map<String, dynamic>>[];
    for (var i = 0; i < history.length; i++) {
      final entry = history[i];
      if (i == history.length - 1 && entry.role == 'user' && contents.isNotEmpty) {
        messages.add({'role': 'user', 'content': [
          ...contents, {'type': 'text', 'text': entry.text} ]});
      } else {
        messages.add({'role': entry.role, 'content': entry.text.isEmpty ? '[Image result]' : entry.text});
      }
    }
    final anthropic = config.protocol == ApiProtocol.anthropic;
    final body = <String, dynamic>{
      'model': config.agentModel, 'messages': [
        if (!anthropic) {'role': 'system', 'content': system}, ...messages],
      if (anthropic) 'system': system,
      if (anthropic) 'max_tokens': 2048,
      'tools': [anthropic ? {
        'name': imageTool['name'], 'description': imageTool['description'],
        'input_schema': imageTool['parameters'],
      } : {'type': 'function', 'function': imageTool}],
      if (!anthropic) 'parallel_tool_calls': false,
    };
    final response = await dio.postUri(config.endpoint(anthropic ? 'messages' : 'chat/completions'),
      data: body, options: Options(headers: agentHeaders), cancelToken: cancel);
    return parseAgentReply(objectResponse(response.data), config.protocol);
  }

  void close() => dio.close(force: true);
}

Dio networkClient(String proxy, {bool followRedirects = true}) {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(minutes: 5), sendTimeout: const Duration(minutes: 2),
    followRedirects: followRedirects));
  if (proxy.trim().isNotEmpty) {
    final uri = Uri.parse(proxy);
    if (uri.scheme != 'http' || uri.host.isEmpty || !uri.hasPort || uri.userInfo.isNotEmpty) {
      throw const FormatException('invalidProxy');
    }
    dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => HttpClient()
      ..findProxy = (_) => 'PROXY ${uri.host}:${uri.port}');
  }
  return dio;
}

/// Retries a request only when it never reached the service, the way ChatBox
/// does: a response, even an error one, means the service answered and retrying
/// would only repeat the same answer.
Future<T> retryNetwork<T>(Future<T> Function() request, {int attempts = 3}) async {
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

int _portOf(Uri uri) => uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

/// The ids out of a `{"data": [{"id": …}]}` model list.
List<String> modelIds(Object? body) {
  final data = objectResponse(body)['data'];
  if (data is! List) throw const FormatException('invalidResponse');
  return data.whereType<Map>().map((e) => e['id']).whereType<String>().toList()..sort();
}

Map<String, dynamic> objectResponse(Object? value) {
  if (value is String) value = jsonDecode(value);
  if (value is! Map<String, dynamic>) throw const FormatException('invalidResponse');
  return value;
}

List<String> imageOutputs(Map<String, dynamic> response) {
  final data = response['data'];
  if (data is! List || data.isEmpty) throw const FormatException('noImage');
  return data.map((item) {
    if (item is! Map) throw const FormatException('invalidResponse');
    final b64 = item['b64_json'];
    if (b64 is String && b64.isNotEmpty) return 'data:image/*;base64,$b64';
    final url = item['url'];
    if (url is String && url.isNotEmpty) return url;
    throw const FormatException('noImage');
  }).toList();
}

AgentReply parseAgentReply(Map<String, dynamic> response, ApiProtocol protocol) {
  final texts = <String>[];
  final prompts = <String>[];
  if (protocol == ApiProtocol.anthropic) {
    final blocks = response['content'];
    if (blocks is! List) throw const FormatException('invalidResponse');
    for (final block in blocks.whereType<Map>()) {
      if (block['type'] == 'text') texts.add(block['text'] as String);
      if (block['type'] == 'tool_use') {
        if (block['name'] != 'generate_image') throw const FormatException('unsupportedTool');
        prompts.add(validatePrompt(block['input']));
      }
    }
  } else {
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) throw const FormatException('invalidResponse');
    final message = choices.first['message'] as Map;
    if (message['content'] is String) texts.add(message['content'] as String);
    final tools = message['tool_calls'] as List? ?? [];
    for (final tool in tools) {
      final fn = tool['function'] as Map;
      if (fn['name'] != 'generate_image') throw const FormatException('unsupportedTool');
      prompts.add(validatePrompt(jsonDecode(fn['arguments'] as String)));
    }
  }
  if (prompts.length > 1) throw const FormatException('multipleCalls');
  if (texts.isEmpty && prompts.isEmpty) throw const FormatException('invalidResponse');
  return AgentReply(texts.join('\n'), prompts.isEmpty ? null : prompts.single);
}

String validatePrompt(Object? input) {
  if (input is! Map || input['prompt'] is! String) throw const FormatException('invalidTool');
  final prompt = (input['prompt'] as String).trim();
  if (prompt.isEmpty || prompt.length > 32000) throw const FormatException('invalidTool');
  return prompt;
}
