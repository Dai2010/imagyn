import 'dart:convert';

enum ApiProtocol { openai, responses, anthropic }

extension ApiProtocolDetails on ApiProtocol {
  String get label => switch (this) {
    ApiProtocol.openai => 'OpenAI · Chat Completions',
    ApiProtocol.responses => 'OpenAI · Responses',
    ApiProtocol.anthropic => 'Anthropic · Messages',
  };
  String get chatPath => switch (this) {
    ApiProtocol.openai => 'chat/completions',
    ApiProtocol.responses => 'responses',
    ApiProtocol.anthropic => 'messages',
  };
}

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
    this.streamAgent = true,
    this.agentProfiles = const {},
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
  final bool streamAgent;
  final Map<String, AgentOptions> agentProfiles;

  AgentOptions get agentOptions =>
      agentProfiles[agentModel] ?? const AgentOptions();

  ServiceConfig copyWith({
    String? agentModel,
    String? imageModel,
    Map<String, AgentOptions>? agentProfiles,
  }) => ServiceConfig(
    baseUrl: baseUrl,
    protocol: protocol,
    imageBaseUrl: imageBaseUrl,
    imageModel: imageModel ?? this.imageModel,
    agentModel: agentModel ?? this.agentModel,
    vision: vision,
    maxReferences: maxReferences,
    proxy: proxy,
    imageStream: imageStream,
    imageResponseB64: imageResponseB64,
    streamAgent: streamAgent,
    agentProfiles: agentProfiles ?? this.agentProfiles,
  );

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
    'streamAgent': streamAgent,
    'agentProfiles': agentProfiles.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };

  factory ServiceConfig.fromJson(Map<String, dynamic> j) => ServiceConfig(
    baseUrl: j['baseUrl'] as String? ?? '',
    protocol: switch (j['protocol']) {
      'anthropic' => ApiProtocol.anthropic,
      'responses' => ApiProtocol.responses,
      _ => ApiProtocol.openai,
    },
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
    streamAgent: j['streamAgent'] != false,
    agentProfiles: (j['agentProfiles'] as Map<String, dynamic>? ?? {}).map(
      (key, value) => MapEntry(
        key,
        AgentOptions.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    ),
  );

  Uri imageEndpoint(String path) => imageBaseUrl.trim().isEmpty
      ? endpoint(path)
      : ServiceConfig(baseUrl: imageBaseUrl).endpoint(path);
}

const defaultAgentPrompt =
    'You are Imagyn, an image creation assistant. Reply in the user language. '
    'Use generate_image only for an explicit request to create or modify an image. '
    'Never claim an image was generated yourself. For discussions reply in text. '
    'Only one generation per turn. Reference images are ordered and supplied to '
    'the image tool by the application. For an edit preserve user constraints. '
    'If the target is unclear, ask. Tool prompts should be self-contained. '
    'When the user asks for a shape or aspect ratio, pass it as aspect_ratio; '
    'never express the ratio only in the prompt text.';

class AgentOptions {
  const AgentOptions({
    this.systemPrompt = defaultAgentPrompt,
    this.contextMessages = 0,
    this.maxOutputTokens,
    this.temperature,
    this.topP,
  });
  final String systemPrompt;
  final int contextMessages;
  final int? maxOutputTokens;
  final double? temperature, topP;

  void validate(ApiProtocol protocol) {
    if (systemPrompt.length > 128000 ||
        contextMessages < 0 ||
        contextMessages > 10000 ||
        (maxOutputTokens != null &&
            (maxOutputTokens! < (protocol == ApiProtocol.responses ? 16 : 1) ||
                maxOutputTokens! > 1048576)) ||
        (temperature != null &&
            (!temperature!.isFinite ||
                temperature! < 0 ||
                temperature! > (protocol == ApiProtocol.anthropic ? 1 : 2))) ||
        (topP != null && (!topP!.isFinite || topP! < 0 || topP! > 1)) ||
        (protocol == ApiProtocol.anthropic &&
            temperature != null &&
            topP != null)) {
      throw const FormatException('invalidAgentOptions');
    }
  }

  List<ChatEntry> selectHistory(List<ChatEntry> history) {
    if (contextMessages == 0 || history.length <= contextMessages) {
      return history;
    }
    var start = history.length - contextMessages;
    // Start with a user message so gateways that require alternating turns work.
    while (start < history.length - 1 && history[start].role != 'user') {
      start++;
    }
    return history.sublist(start);
  }

  Map<String, dynamic> toJson() => {
    'systemPrompt': systemPrompt,
    'contextMessages': contextMessages,
    'maxOutputTokens': maxOutputTokens,
    'temperature': temperature,
    'topP': topP,
  };
  factory AgentOptions.fromJson(Map<String, dynamic> value) => AgentOptions(
    systemPrompt: value['systemPrompt'] as String? ?? defaultAgentPrompt,
    contextMessages: (value['contextMessages'] as num? ?? 0).toInt(),
    maxOutputTokens: (value['maxOutputTokens'] as num?)?.toInt(),
    temperature: (value['temperature'] as num?)?.toDouble(),
    topP: (value['topP'] as num?)?.toDouble(),
  );
}

class ImageOptions {
  const ImageOptions({
    this.size = 'auto',
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
    size: value['size'] as String? ?? 'auto',
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
  const ChatEntry(
    this.role,
    this.text, {
    this.assetIds = const [],
    this.model,
    this.reasoning = '',
  });
  final String role, text;
  final String? model;

  /// What the model thought before answering, when the service exposes it.
  final String reasoning;
  final List<String> assetIds;
  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'assetIds': assetIds,
    if (model != null) 'model': model,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
  };
  factory ChatEntry.fromJson(Map<String, dynamic> j) => ChatEntry(
    j['role'] as String,
    j['text'] as String,
    model: j['model'] as String?,
    reasoning: j['reasoning'] as String? ?? '',
    assetIds: List<String>.from(j['assetIds'] as List? ?? []),
  );
}

String encodeRecord(Map<String, dynamic> value) => jsonEncode(value);

/// The ratios the picker offers and the tool accepts, with the exact pixels
/// handed to the Images API (the reference implementation's 1K tier). The wire
/// protocol has no ratio field, so a ratio always travels as one of these pairs.
const sizePresets = <String, String>{
  '1:1': '1024x1024',
  '3:2': '1536x1024',
  '2:3': '1024x1536',
  '16:9': '1280x720',
  '9:16': '720x1280',
  '4:3': '1024x768',
  '3:4': '768x1024',
  '21:9': '1280x544',
};

/// The ratio a stored size came from, or null for `auto` and for sizes saved by
/// an older build that are not one of the presets.
String? ratioOfSize(String size) {
  for (final entry in sizePresets.entries) {
    if (entry.value == size) return entry.key;
  }
  return null;
}

const imageTool = {
  'name': 'generate_image',
  'description':
      'Generate or edit an image only when the user asks for an image. '
      'Reference images are supplied by the app. Return a detailed prompt.',
  'parameters': {
    'type': 'object',
    'properties': {
      'prompt': {'type': 'string'},
      // OpenAI strict tools require every property to be listed as required,
      // so `auto` is an explicit choice rather than an omitted one.
      'aspect_ratio': {
        'type': 'string',
        'enum': [
          'auto',
          '1:1',
          '3:2',
          '2:3',
          '16:9',
          '9:16',
          '4:3',
          '3:4',
          '21:9',
        ],
        'description':
            'The aspect ratio the user asked for. Use auto when the user did '
            'not ask for one; the app then keeps the ratio chosen in its '
            'options.',
      },
    },
    'required': ['prompt', 'aspect_ratio'],
    'additionalProperties': false,
  },
};
