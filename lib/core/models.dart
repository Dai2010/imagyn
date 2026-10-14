import 'dart:convert';

enum ApiProtocol { openai, anthropic }

class ServiceConfig {
  const ServiceConfig({
    this.baseUrl = '',
    this.protocol = ApiProtocol.openai,
    this.imageModel = '',
    this.imageBaseUrl = '',
    this.agentModel = '',
    this.vision = false,
    this.maxReferences = 4,
    this.proxy = '',
  });
  final String baseUrl;
  final ApiProtocol protocol;
  final String imageModel;
  final String imageBaseUrl;
  final String agentModel;
  final bool vision;
  final int maxReferences;
  final String proxy;

  Uri endpoint(String path) {
    final base = Uri.parse(baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''));
    if (!['https', 'http'].contains(base.scheme) || base.host.isEmpty ||
        base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw const FormatException('invalidEndpoint');
    }
    return base.replace(path: '${base.path}/$path');
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl, 'protocol': protocol.name, 'imageModel': imageModel,
    'agentModel': agentModel, 'vision': vision,
    'imageBaseUrl': imageBaseUrl,
    'maxReferences': maxReferences, 'proxy': proxy,
  };

  factory ServiceConfig.fromJson(Map<String, dynamic> j) => ServiceConfig(
    baseUrl: j['baseUrl'] as String? ?? '',
    protocol: j['protocol'] == 'anthropic' ? ApiProtocol.anthropic : ApiProtocol.openai,
    imageModel: j['imageModel'] as String? ?? '',
    imageBaseUrl: j['imageBaseUrl'] as String? ?? '',
    agentModel: j['agentModel'] as String? ?? '',
    vision: j['vision'] == true,
    maxReferences: (j['maxReferences'] as num? ?? 4).toInt().clamp(1, 16).toInt(),
    proxy: j['proxy'] as String? ?? '',
  );

  Uri imageEndpoint(String path) => imageBaseUrl.trim().isEmpty
    ? endpoint(path) : ServiceConfig(baseUrl: imageBaseUrl).endpoint(path);
}

class Asset {
  const Asset({required this.id, required this.path, required this.mime,
    required this.prompt, required this.createdAt, this.parentId});
  final String id, path, mime, prompt;
  final DateTime createdAt;
  final String? parentId;
  Map<String, dynamic> toJson() => {'id': id, 'path': path, 'mime': mime,
    'prompt': prompt, 'createdAt': createdAt.toIso8601String(), 'parentId': parentId};
  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
    id: j['id'] as String, path: j['path'] as String,
    mime: j['mime'] as String, prompt: j['prompt'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String), parentId: j['parentId'] as String?);
}

class ChatEntry {
  const ChatEntry(this.role, this.text, {this.assetIds = const []});
  final String role, text;
  final List<String> assetIds;
  Map<String, dynamic> toJson() => {'role': role, 'text': text, 'assetIds': assetIds};
  factory ChatEntry.fromJson(Map<String, dynamic> j) => ChatEntry(
    j['role'] as String, j['text'] as String,
    assetIds: List<String>.from(j['assetIds'] as List? ?? []));
}

String encodeRecord(Map<String, dynamic> value) => jsonEncode(value);

const imageTool = {
  'name': 'generate_image',
  'description': 'Generate or edit an image only when the user asks for an image. '
      'Reference images are supplied by the app. Return a detailed prompt.',
  'parameters': {
    'type': 'object',
    'properties': {'prompt': {'type': 'string'}},
    'required': ['prompt'],
    'additionalProperties': false,
  },
};
