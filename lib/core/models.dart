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
    this.imageStream = false,
    this.imageResponseB64 = false,
  });
  final String baseUrl;
  final ApiProtocol protocol;
  final String imageModel;
  final String imageBaseUrl;
  final String agentModel;
  final bool vision;
  final int maxReferences;
  final String proxy;
  final bool imageStream, imageResponseB64;

  Uri endpoint(String path) {
    final base = Uri.parse(baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''));
    if (!['https', 'http'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException('invalidEndpoint');
    }
    return base.replace(path: '${base.path}/$path');
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'protocol': protocol.name,
    'imageModel': imageModel,
    'agentModel': agentModel,
    'vision': vision,
    'imageBaseUrl': imageBaseUrl,
    'maxReferences': maxReferences,
    'proxy': proxy,
    'imageStream': imageStream,
    'imageResponseB64': imageResponseB64,
  };

  factory ServiceConfig.fromJson(Map<String, dynamic> j) => ServiceConfig(
    baseUrl: j['baseUrl'] as String? ?? '',
    protocol: j['protocol'] == 'anthropic'
        ? ApiProtocol.anthropic
        : ApiProtocol.openai,
    imageModel: j['imageModel'] as String? ?? '',
    imageBaseUrl: j['imageBaseUrl'] as String? ?? '',
    agentModel: j['agentModel'] as String? ?? '',
    vision: j['vision'] == true,
    maxReferences: (j['maxReferences'] as num? ?? 4)
        .toInt()
        .clamp(1, 16)
        .toInt(),
    proxy: j['proxy'] as String? ?? '',
    imageStream: j['imageStream'] == true,
    imageResponseB64: j['imageResponseB64'] == true,
  );

  Uri imageEndpoint(String path) => imageBaseUrl.trim().isEmpty
      ? endpoint(path)
      : ServiceConfig(baseUrl: imageBaseUrl).endpoint(path);
}

class ImageOptions {
  const ImageOptions({
    this.size = '1024x1024',
    this.quality = 'auto',
    this.format = 'png',
    this.transparent = false,
    this.moderation = 'auto',
    this.count = 1,
  });
  final String size, quality, format, moderation;
  final bool transparent;
  final int count;

  ImageOptions copyWith({
    String? size,
    String? quality,
    String? format,
    bool? transparent,
    String? moderation,
    int? count,
  }) => ImageOptions(
    size: size ?? this.size,
    quality: quality ?? this.quality,
    format: format ?? this.format,
    transparent: transparent ?? this.transparent,
    moderation: moderation ?? this.moderation,
    count: count ?? this.count,
  );

  void validate() {
    if ((size != 'auto' &&
            !RegExp(r'^[1-9]\d{1,4}x[1-9]\d{1,4}$').hasMatch(size)) ||
        !['auto', 'low', 'medium', 'high', 'xhigh', 'max'].contains(quality) ||
        !['png', 'jpeg', 'webp'].contains(format) ||
        !['auto', 'low'].contains(moderation) ||
        count < 1 ||
        count > 10 ||
        (transparent && format == 'jpeg')) {
      throw const FormatException('invalidImageOptions');
    }
  }

  Map<String, dynamic> toJson() => {
    'size': size,
    'quality': quality,
    'output_format': format,
    'transparent': transparent,
    'moderation': moderation,
    'n': count,
  };

  factory ImageOptions.fromJson(Map<String, dynamic> value) => ImageOptions(
    size: value['size'] as String? ?? '1024x1024',
    quality: value['quality'] as String? ?? 'auto',
    format: value['output_format'] as String? ?? 'png',
    transparent: value['transparent'] == true,
    moderation: value['moderation'] as String? ?? 'auto',
    count: (value['n'] as num? ?? 1).toInt(),
  );

  Map<String, dynamic> requestFields() {
    validate();
    return {
      'size': size,
      'quality': quality,
      'output_format': format,
      'moderation': moderation,
      if (transparent) 'background': 'transparent',
      if (count > 1) 'n': count,
    };
  }
}

class ImageJob {
  const ImageJob(this.id, this.state, this.record);
  final String id, state;
  final Map<String, dynamic> record;
  String get prompt => record['prompt'] as String? ?? '';
  ImageOptions get options => ImageOptions.fromJson(record);
}

class Asset {
  const Asset({
    required this.id,
    required this.path,
    required this.mime,
    required this.prompt,
    required this.createdAt,
    this.parentId,
    this.parameters = const {},
  });
  final String id, path, mime, prompt;
  final DateTime createdAt;
  final String? parentId;
  final Map<String, dynamic> parameters;
  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'mime': mime,
    'prompt': prompt,
    'createdAt': createdAt.toIso8601String(),
    'parentId': parentId,
    'parameters': parameters,
  };
  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
    id: j['id'] as String,
    path: j['path'] as String,
    mime: j['mime'] as String,
    prompt: j['prompt'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    parentId: j['parentId'] as String?,
    parameters: Map<String, dynamic>.from(j['parameters'] as Map? ?? {}),
  );
}

class ChatEntry {
  const ChatEntry(this.role, this.text, {this.assetIds = const []});
  final String role, text;
  final List<String> assetIds;
  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'assetIds': assetIds,
  };
  factory ChatEntry.fromJson(Map<String, dynamic> j) => ChatEntry(
    j['role'] as String,
    j['text'] as String,
    assetIds: List<String>.from(j['assetIds'] as List? ?? []),
  );
}

String encodeRecord(Map<String, dynamic> value) => jsonEncode(value);

const imageTool = {
  'name': 'generate_image',
  'description':
      'Generate or edit an image only when the user asks for an image. '
      'Reference images are supplied by the app. Return a detailed prompt.',
  'parameters': {
    'type': 'object',
    'properties': {
      'prompt': {'type': 'string'},
    },
    'required': ['prompt'],
    'additionalProperties': false,
  },
};
