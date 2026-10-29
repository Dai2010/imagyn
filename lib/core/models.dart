import 'dart:convert';

import 'styles.dart';
import 'video.dart';

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
    this.videoBaseUrl = '',
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
  final String videoBaseUrl;
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
    videoBaseUrl: videoBaseUrl,
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
    'videoBaseUrl': videoBaseUrl,
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
    videoBaseUrl: j['videoBaseUrl'] as String? ?? '',
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

  /// Video can live on its own service: a gateway that renders clips is often
  /// not the one that renders stills. Empty means "the image service", which
  /// itself falls back to the main one.
  Uri videoEndpoint(String path) => videoBaseUrl.trim().isEmpty
      ? imageEndpoint(path)
      : ServiceConfig(baseUrl: videoBaseUrl).endpoint(path);
}

const deckAgentPrompt =
    'You are Imagyn, an image and slide-deck assistant. Reply in the user language. '
    'Use generate_image only for an explicit image request or a picture a page needs; '
    'never claim you generated an image yourself. '
    'For decks: create_deck, add_slide once per page, finish_deck. A deck is editable '
    'text and pictures, not a picture of a slide. Pass the exact image_id that '
    'generate_image returned, or "last", as image_id; never a description. '
    'Call tools repeatedly in one turn until the deck is done, then answer briefly. '
    'On a tool error read the code: retry with changed arguments, change approach, or '
    'use ask_user; never repeat the same failing call. ask_user ends the turn and the '
    'user\'s next message is the answer. '
    'Discuss in text. Reference images come from the app, in order; keep the user\'s '
    'constraints. Ask when the target is unclear. '
    'Pass a requested shape as aspect_ratio, not only in the prompt text.';

const tableAgentPrompt =
    '$deckAgentPrompt '
    'For tables call add_table after add_slide with the zero-based index, rectangular '
    'string rows and header_row: cells stay editable. A page holds up to two tables, '
    'stacked in call order; table_index -1 appends, 0 or 1 replaces that table. '
    'add_chart replaces the page\'s chart; a pie uses only the first series. '
    'Split large tables across pages. bullet_levels on add_slide/update_slide indents '
    'sub-points (0-2). set_notes writes speaker notes that never appear on the slide.';

/// Shipped with the app and never edited by the user: it only explains the
/// tools. A build that adds a tool adds its instructions here, so the model
/// cannot lose them by rewriting the user-facing prompt.
const builtInAgentPrompt =
    '$tableAgentPrompt '
    'set_background puts a generated picture behind a page: pass the deck id, '
    'image_id (or "last") and index (-1 for every page). The app adds a light '
    'scrim, so avoid busy backgrounds. '
    'add_text and add_image place styled, editable elements at fractional page '
    'coordinates (x, y, width, height in 0..1), so one page can carry several '
    'pictures, captions and decoration. Pages are near-white: default to dark '
    'text unless you set a fill. For a designed text box combine fill with fill2 '
    '(gradient), border, radius, shadow and rotation (degrees); widen short '
    'display words with letter_spacing and keep body text plain so it stays '
    'readable. remove_element deletes one element by the id the tool returned. '
    'For a public link or page call fetch_url with an absolute URL and a '
    'format: it returns that page as markdown by default and refuses private '
    'addresses. Do not repeat a failed fetch; '
    'say what went wrong. A user message may carry <file name="…"> blocks: '
    'treat their contents as source material for the request. '
    'generate_video renders a short clip when the user explicitly asks for a '
    'video: it takes minutes and the clip is saved to the video page, so never '
    'describe it as an inline picture and never call it for a still. '
    'Each generated picture shows under the call that made it; refer back to '
    'one by its image_id. list_images lists older ones with their ids: pass up '
    'to ten ids as reference_ids to reuse them, or delete_image to remove one, '
    'and only one the user asked to delete.';

/// The editable prompt starts empty: the tool instructions above are always
/// sent, and this is where the user adds their own standing instructions.
const defaultAgentPrompt = '';

/// The prompt shipped before the deck tools. A saved profile that still holds
/// it verbatim is upgraded on load; a prompt the user edited is kept as is.
const legacyAgentPrompt =
    'You are Imagyn, an image creation assistant. Reply in the user language. '
    'Use generate_image only for an explicit request to create or modify an image. '
    'Never claim an image was generated yourself. For discussions reply in text. '
    'Only one generation per turn. Reference images are ordered and supplied to '
    'the image tool by the application. For an edit preserve user constraints. '
    'If the target is unclear, ask. Tool prompts should be self-contained. '
    'When the user asks for a shape or aspect ratio, pass it as aspect_ratio; '
    'never express the ratio only in the prompt text.';

/// A starting point for the two token fields. Only the windows a service
/// documents are preset; sampling stays with the service, and every value can
/// still be edited after it is applied.
class AgentPreset {
  const AgentPreset({
    required this.model,
    required this.contextTokens,
    required this.maxOutputTokens,
  });
  final String model;
  final int contextTokens, maxOutputTokens;
}

/// Reference values for the models this app is usually pointed at. Services
/// change their windows, so these are suggestions rather than guarantees.
/// Only windows a vendor documents are listed; a model whose output limit is
/// unpublished stays out rather than carrying a guessed number.
const agentPresets = <AgentPreset>[
  AgentPreset(
    model: 'deepseek-flash',
    contextTokens: 1000000,
    maxOutputTokens: 384000,
  ),
  AgentPreset(
    model: 'deepseek-v4-pro',
    contextTokens: 1000000,
    maxOutputTokens: 384000,
  ),
  AgentPreset(
    model: 'glm-5.3',
    contextTokens: 1000000,
    maxOutputTokens: 128000,
  ),
  AgentPreset(
    model: 'glm-5.3-flash',
    contextTokens: 1000000,
    maxOutputTokens: 128000,
  ),
  AgentPreset(
    model: 'glm-5.2',
    contextTokens: 1000000,
    maxOutputTokens: 128000,
  ),
  AgentPreset(
    model: 'glm-4.7',
    contextTokens: 200000,
    maxOutputTokens: 128000,
  ),
];

/// A starting point for the image model field. [maxReferences] is filled only
/// for models whose editing interface documents a reference count.
class ImagePreset {
  const ImagePreset({required this.model, this.maxReferences});
  final String model;
  final int? maxReferences;
}

const imagePresets = <ImagePreset>[
  ImagePreset(model: 'glm-image'),
  ImagePreset(model: 'qwen-image-3.0-pro', maxReferences: 3),
  ImagePreset(model: 'qwen-image-2.0-pro', maxReferences: 3),
  ImagePreset(model: 'wan2.7-image-pro'),
];

class AgentOptions {
  const AgentOptions({
    this.systemPrompt = defaultAgentPrompt,
    this.contextMessages = 0,
    this.contextTokens = 0,
    this.maxOutputTokens,
    this.temperature,
    this.topP,
  });
  final String systemPrompt;
  final int contextMessages;

  /// The model's input window in tokens, when the user knows it. Zero leaves
  /// compaction off; a positive value makes a long conversation summarize its
  /// older turns before the request would fail on length.
  final int contextTokens;
  final int? maxOutputTokens;
  final double? temperature, topP;

  AgentOptions copyWith({
    String? systemPrompt,
    int? contextMessages,
    int? contextTokens,
    int? maxOutputTokens,
    double? temperature,
    double? topP,
  }) => AgentOptions(
    systemPrompt: systemPrompt ?? this.systemPrompt,
    contextMessages: contextMessages ?? this.contextMessages,
    contextTokens: contextTokens ?? this.contextTokens,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    temperature: temperature ?? this.temperature,
    topP: topP ?? this.topP,
  );

  /// What actually travels as the system prompt: the built-in tool
  /// instructions, then the user's own additions when they wrote any.
  String get requestPrompt {
    final user = systemPrompt.trim();
    return user.isEmpty ? builtInAgentPrompt : '$builtInAgentPrompt\n\n$user';
  }

  void validate(ApiProtocol protocol) {
    if (systemPrompt.length > 128000 ||
        contextMessages < 0 ||
        contextMessages > 10000 ||
        contextTokens < 0 ||
        contextTokens > 10000000 ||
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
    'contextTokens': contextTokens,
    'maxOutputTokens': maxOutputTokens,
    'temperature': temperature,
    'topP': topP,
  };
  factory AgentOptions.fromJson(Map<String, dynamic> value) {
    final stored = value['systemPrompt'] as String?;
    return AgentOptions(
      // Older builds shipped the tool instructions inside the editable prompt.
      // Now that they are built in, the editable half starts empty unless the
      // user wrote something of their own.
      systemPrompt:
          stored == null ||
              stored == legacyAgentPrompt ||
              stored == deckAgentPrompt ||
              stored == tableAgentPrompt ||
              stored == builtInAgentPrompt
          ? defaultAgentPrompt
          : stored,
      contextMessages: (value['contextMessages'] as num? ?? 0).toInt(),
      contextTokens: (value['contextTokens'] as num? ?? 0).toInt(),
      maxOutputTokens: (value['maxOutputTokens'] as num?)?.toInt(),
      temperature: (value['temperature'] as num?)?.toDouble(),
      topP: (value['topP'] as num?)?.toDouble(),
    );
  }
}

class ImageOptions {
  const ImageOptions({
    this.size = 'auto',
    this.quality = 'auto',
    this.format = 'png',
    this.transparent = false,
    this.moderation = 'auto',
    this.count = 1,
    this.style = '',
  });
  final String size, quality, format, moderation;

  /// The id of the style pack to apply, or empty for none. Kept out of
  /// [requestFields]: the words travel inside the prompt, not as a parameter.
  final String style;
  final bool transparent;
  final int count;

  ImageOptions copyWith({
    String? size,
    String? quality,
    String? format,
    bool? transparent,
    String? moderation,
    int? count,
    String? style,
  }) => ImageOptions(
    size: size ?? this.size,
    quality: quality ?? this.quality,
    format: format ?? this.format,
    transparent: transparent ?? this.transparent,
    moderation: moderation ?? this.moderation,
    count: count ?? this.count,
    style: style ?? this.style,
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
    if (style.isNotEmpty) 'style': style,
  };

  factory ImageOptions.fromJson(Map<String, dynamic> value) => ImageOptions(
    size: value['size'] as String? ?? 'auto',
    quality: value['quality'] as String? ?? 'auto',
    format: value['output_format'] as String? ?? 'png',
    transparent: value['transparent'] == true,
    moderation: value['moderation'] as String? ?? 'auto',
    count: (value['n'] as num? ?? 1).toInt(),
    style: value['style'] as String? ?? '',
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

/// One tool call exactly as the service sent it.
///
/// The arguments are not validated here: whether they make sense is the
/// executor's question. A call to a tool this build does not know has to be
/// answerable with an error, not allowed to fail the whole turn — otherwise a
/// model that tries one unknown tool loses its answer as well.
class AgentCall {
  const AgentCall(this.id, this.name, this.arguments);
  final String id, name;
  final Map<String, dynamic> arguments;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };
  factory AgentCall.fromJson(Map<String, dynamic> j) => AgentCall(
    j['id'] as String,
    j['name'] as String,
    Map<String, dynamic>.from(j['arguments'] as Map),
  );
}

class ChatEntry {
  const ChatEntry(
    this.role,
    this.text, {
    this.assetIds = const [],
    this.model,
    this.reasoning = '',
    this.calls = const [],
    this.callId,
    this.name,
    this.aborted = false,
  });
  final String role, text;
  final String? model;

  /// What the model thought before answering, when the service exposes it.
  final String reasoning;
  final List<String> assetIds;

  /// The calls this turn asked for. A turn that calls a tool carries no answer
  /// yet; the answer arrives after the results are sent back in the next one.
  final List<AgentCall> calls;

  /// Set on the entry carrying a tool's result: which call it answers.
  final String? callId;

  /// The tool a result entry belongs to, so the transcript can label a result
  /// without looking the call up.
  final String? name;

  /// True when the user stopped the turn: the text is what had already
  /// streamed, not a finished answer. The local transcript keeps it — stopping
  /// is usually a way to get a word in — but the UI says so.
  final bool aborted;

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'assetIds': assetIds,
    if (model != null) 'model': model,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (calls.isNotEmpty) 'calls': calls.map((call) => call.toJson()).toList(),
    if (callId != null) 'callId': callId,
    if (name != null) 'name': name,
    if (aborted) 'aborted': true,
  };
  factory ChatEntry.fromJson(Map<String, dynamic> j) => ChatEntry(
    j['role'] as String,
    j['text'] as String,
    model: j['model'] as String?,
    reasoning: j['reasoning'] as String? ?? '',
    assetIds: List<String>.from(j['assetIds'] as List? ?? []),
    calls: [
      for (final call in j['calls'] as List? ?? [])
        AgentCall.fromJson(Map<String, dynamic>.from(call as Map)),
    ],
    callId: j['callId'] as String?,
    name: j['name'] as String?,
    aborted: j['aborted'] == true,
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
      'Generate or edit an image only when the user asks for an image or a '
      'deck page needs a picture. Reference images are supplied by the app. '
      'Return a detailed prompt. The result names an image_id: pass it to '
      'add_slide (or pass "last") so the page carries the picture.',
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
      'quality': {
        'type': 'string',
        'enum': ['auto', 'low', 'medium', 'high'],
        'description':
            'The quality the user asked for. Use auto when the user did not '
            'ask; the app then keeps the quality chosen in its options.',
      },
      'style': {
        'type': 'string',
        'enum': styleChoices,
        'description':
            'The drawing style the user asked for (cel, painterly, flat, '
            'watercolor, pixel, film). Use auto when the user did not ask; the '
            'app then keeps the style chosen in its options. Custom styles '
            'live only in the app, so never invent an id.',
      },
      'reference_ids': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'Ids of earlier pictures to feed the image model, from list_images '
            'or an earlier generate_image. Empty means the pictures attached '
            'in the app.',
      },
    },
    'required': [
      'prompt',
      'aspect_ratio',
      'quality',
      'style',
      'reference_ids',
    ],
    'additionalProperties': false,
  },
};

const listImagesTool = {
  'name': 'list_images',
  'description':
      'List the pictures in the gallery, newest first, with their ids, dates '
      'and prompts. Use it before reusing or deleting an older picture: the '
      'ids it returns are what generate_image and delete_image accept.',
  'parameters': {
    'type': 'object',
    'properties': {
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 50,
        'description': 'How many pictures to list, newest first.',
      },
      'query': {
        'type': 'string',
        'description':
            'Words to match against the prompt, case-insensitive. Empty lists '
            'the newest pictures.',
      },
    },
    'required': ['limit', 'query'],
    'additionalProperties': false,
  },
};

const deleteImageTool = {
  'name': 'delete_image',
  'description':
      'Delete one picture from the gallery permanently. Only an id that '
      'list_images or generate_image returned in this conversation can be '
      'deleted, and only when the user asked to remove that picture.',
  'parameters': {
    'type': 'object',
    'properties': {
      'image_id': {'type': 'string'},
    },
    'required': ['image_id'],
    'additionalProperties': false,
  },
};

const videoTool = {
  'name': 'generate_video',
  'description':
      'Render a short video clip from a prompt. Use it only when the user '
      'explicitly asks for a video: it takes minutes and the clip is saved to '
      'the video page, so never describe it as an inline picture. The newest '
      'conversation image, if any, is used as the first frame.',
  'parameters': {
    'type': 'object',
    'properties': {
      'prompt': {'type': 'string'},
      'model': {
        'type': 'string',
        'description':
            'Video model id for this clip, e.g. seedance-1-0-pro-250528. Leave '
            'it empty to use the model chosen on the video page; a gateway may '
            'accept ids that are not in the built-in list.',
      },
      'ratio': {
        'type': 'string',
        'enum': VideoOptions.ratios,
        'description':
            'The shape of the clip. Use 16:9 unless the user asks otherwise.',
      },
      'resolution': {
        'type': 'string',
        'enum': VideoOptions.resolutions,
      },
      'seconds': {
        'type': 'integer',
        'minimum': VideoOptions.minSeconds,
        'maximum': VideoOptions.maxSeconds,
      },
      'watermark': {'type': 'boolean'},
      'camera_fixed': {
        'type': 'boolean',
        'description': 'Keep the camera still instead of moving it.',
      },
      'seed': {
        'type': 'integer',
        'minimum': -1,
        'description': '-1 lets the service choose; reuse a value to repeat a '
            'previous clip.',
      },
      'style': {
        'type': 'string',
        'enum': styleChoices,
        'description':
            'The drawing style the user asked for. Use auto when the user did '
            'not ask; the app then keeps the style chosen in its options. '
            'Custom styles live only in the app, so never invent an id.',
      },
    },
    'required': [
      'prompt',
      'model',
      'ratio',
      'resolution',
      'seconds',
      'watermark',
      'camera_fixed',
      'seed',
      'style',
    ],
    'additionalProperties': false,
  },
};

enum SlideElementKind { text, image }

bool _isHexColor(String value) =>
    RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(value);

/// A shape placed freely on a page: a styled text box or a picture.
///
/// Coordinates are fractions of the page (0..1): x/y is the top-left corner
/// and width/height the box size. One element list therefore renders the same
/// in the workspace and in the exported `.pptx`, whatever the slide size.
/// The factory validates every field, so a bad rectangle from the model comes
/// back as a tool error instead of an archive Office refuses to open.
class SlideElement {
  factory SlideElement({
    required String id,
    required SlideElementKind kind,
    required double x,
    required double y,
    required double width,
    required double height,
    String text = '',
    String? imageId,
    double fontSize = 18,
    String color = '1F1B2E',
    bool bold = false,
    bool italic = false,
    String align = 'left',
    String? fill,
    String? fill2,
    String? border,
    double radius = 0,
    bool shadow = false,
    double rotation = 0,
    double letterSpacing = 0,
    String fit = 'cover',
    String? font,
    double? padding,
    double lineSpacing = 1.15,
  }) {
    // Models habitually write `#RRGGBB` although the schema says RRGGBB;
    // accepting the prefix is cheaper than answering with an error.
    String? rgb(String? value) => value == null
        ? null
        : (value.startsWith('#') ? value.substring(1) : value);
    final ink = rgb(color);
    final fillRgb = rgb(fill);
    final gradientRgb = rgb(fill2);
    final borderRgb = rgb(border);
    final family = font?.trim();
    if (id.isEmpty ||
        id.length > 64 ||
        !x.isFinite ||
        !y.isFinite ||
        !width.isFinite ||
        !height.isFinite ||
        x < 0 ||
        y < 0 ||
        width <= 0 ||
        height <= 0 ||
        x + width > 1.0001 ||
        y + height > 1.0001 ||
        text.length > maxTextLength ||
        (kind == SlideElementKind.text && text.trim().isEmpty) ||
        (kind == SlideElementKind.image &&
            (imageId == null || imageId.isEmpty)) ||
        !fontSize.isFinite ||
        fontSize < 6 ||
        fontSize > 200 ||
        !radius.isFinite ||
        radius < 0 ||
        radius > .5 ||
        (family != null &&
            (family.length > 64 ||
                family.contains(RegExp(r'[\x00-\x1F]')))) ||
        (padding != null &&
            (!padding.isFinite || padding < 0 || padding > 72)) ||
        !lineSpacing.isFinite ||
        lineSpacing < .7 ||
        lineSpacing > 3 ||
        !alignValues.contains(align) ||
        !fitValues.contains(fit) ||
        !_isHexColor(ink!) ||
        (fillRgb != null && !_isHexColor(fillRgb)) ||
        (gradientRgb != null && !_isHexColor(gradientRgb)) ||
        !rotation.isFinite ||
        rotation < -45 ||
        rotation > 45 ||
        !letterSpacing.isFinite ||
        letterSpacing < -2 ||
        letterSpacing > 20 ||
        (borderRgb != null && !_isHexColor(borderRgb))) {
      throw const FormatException('invalidSlideElement');
    }
    return SlideElement._(
      id: id,
      kind: kind,
      x: x,
      y: y,
      width: width,
      height: height,
      text: text,
      imageId: imageId,
      fontSize: fontSize,
      color: ink.toUpperCase(),
      bold: bold,
      italic: italic,
      align: align,
      fill: fillRgb?.toUpperCase(),
      fill2: gradientRgb?.toUpperCase(),
      border: borderRgb?.toUpperCase(),
      radius: radius,
      shadow: shadow,
      rotation: rotation,
      letterSpacing: letterSpacing,
      fit: fit,
      font: family == null || family.isEmpty ? null : family,
      padding: padding,
      lineSpacing: lineSpacing,
    );
  }

  const SlideElement._({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.text,
    required this.imageId,
    required this.fontSize,
    required this.color,
    required this.bold,
    required this.italic,
    required this.align,
    required this.fill,
    required this.fill2,
    required this.border,
    required this.radius,
    required this.shadow,
    required this.rotation,
    required this.letterSpacing,
    required this.fit,
    required this.font,
    required this.padding,
    required this.lineSpacing,
  });

  /// Enough shapes to build a poster-like page, few enough that the model
  /// cannot turn a slide into a thousand-element document.
  static const maxCount = 24;
  static const maxTextLength = 2000;
  static const alignValues = ['left', 'center', 'right'];
  static const fitValues = ['cover', 'contain'];

  /// Stable within a slide; `remove_element` names an element by this.
  final String id;
  final SlideElementKind kind;
  final double x, y, width, height;

  /// Text content, and the picture to draw, respectively.
  final String text;
  final String? imageId;

  /// Points, matching the size the exported text has in PowerPoint.
  final double fontSize;
  final String color;
  final bool bold;
  final bool italic;
  final String align;

  /// `RRGGBB` or null for no fill; a text box's background and outline.
  final String? fill;

  /// Second gradient stop, top-left to bottom-right. Null keeps [fill] solid.
  final String? fill2;
  final String? border;

  /// Corner curve as a fraction of the shorter side, 0..0.5.
  final double radius;

  /// A soft drop shadow, for cards and callouts that should lift off the page.
  final bool shadow;

  /// Degrees, -45..45. Used for tilted labels and poster-like headings.
  final double rotation;

  /// Extra space between characters in points, -2..20.
  final double letterSpacing;

  /// How a picture fills its box: `cover` crops, `contain` letterboxes.
  final String fit;

  /// Typeface for a text box; null keeps the theme font.
  final String? font;

  /// Point insets inside a text box; null uses a size-proportional default.
  final double? padding;

  /// Paragraph line height as a multiple of the font size.
  final double lineSpacing;

  /// Replaces the asset id after an import has saved the picture bytes.
  SlideElement withImage(String imageId) => SlideElement._(
    id: id,
    kind: kind,
    x: x,
    y: y,
    width: width,
    height: height,
    text: text,
    imageId: imageId,
    fontSize: fontSize,
    color: color,
    bold: bold,
    italic: italic,
    align: align,
    fill: fill,
    fill2: fill2,
    border: border,
    radius: radius,
    shadow: shadow,
    rotation: rotation,
    letterSpacing: letterSpacing,
    fit: fit,
    font: font,
    padding: padding,
    lineSpacing: lineSpacing,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    if (text.isNotEmpty) 'text': text,
    if (imageId != null) 'imageId': imageId,
    'fontSize': fontSize,
    'color': color,
    'bold': bold,
    'italic': italic,
    'align': align,
    if (fill != null) 'fill': fill,
    if (fill2 != null) 'fill2': fill2,
    if (border != null) 'border': border,
    'radius': radius,
    if (shadow) 'shadow': true,
    if (rotation != 0) 'rotation': rotation,
    if (letterSpacing != 0) 'letterSpacing': letterSpacing,
    'fit': fit,
    if (font != null) 'font': font,
    if (padding != null) 'padding': padding,
    'lineSpacing': lineSpacing,
  };

  factory SlideElement.fromJson(Map<String, dynamic> j) => SlideElement(
    id: j['id'] as String? ?? '',
    kind: j['kind'] == 'image'
        ? SlideElementKind.image
        : SlideElementKind.text,
    x: (j['x'] as num? ?? 0).toDouble(),
    y: (j['y'] as num? ?? 0).toDouble(),
    width: (j['width'] as num? ?? 0).toDouble(),
    height: (j['height'] as num? ?? 0).toDouble(),
    text: j['text'] as String? ?? '',
    imageId: j['imageId'] as String?,
    fontSize: (j['fontSize'] as num? ?? 18).toDouble(),
    color: j['color'] as String? ?? '1F1B2E',
    bold: j['bold'] == true,
    italic: j['italic'] == true,
    align: j['align'] as String? ?? 'left',
    fill: j['fill'] as String?,
    fill2: j['fill2'] as String?,
    border: j['border'] as String?,
    radius: (j['radius'] as num? ?? 0).toDouble(),
    shadow: j['shadow'] == true,
    rotation: (j['rotation'] as num? ?? 0).toDouble(),
    letterSpacing: (j['letterSpacing'] as num? ?? 0).toDouble(),
    fit: j['fit'] as String? ?? 'cover',
    font: j['font'] as String?,
    padding: (j['padding'] as num?)?.toDouble(),
    lineSpacing: (j['lineSpacing'] as num? ?? 1.15).toDouble(),
  );
}

/// One slide: what a deck tool adds, and what the workspace renders.
class Slide {
  const Slide({
    this.title = '',
    this.bullets = const [],
    this.bulletLevels = const [],
    this.notes = '',
    this.imageId,
    this.backgroundImageId,
    this.backgroundColor,
    this.tables = const [],
    this.chart,
    this.table,
    this.elements = const [],
  });
  final String title;
  final List<String> bullets;

  /// Indent level per bullet, 0 (top) to 2. Shorter than [bullets] means the
  /// remaining lines sit at the top level.
  final List<int> bulletLevels;

  /// Speaker notes: shown in the workspace and written to the notes pages of
  /// the exported .pptx, never drawn on the slide itself.
  final String notes;
  final String? imageId;

  /// A picture behind the whole page. Null inherits the deck background; an
  /// empty string means this page has none even when the deck has one.
  final String? backgroundImageId;

  /// A solid `RRGGBB` behind the page, used when no picture is resolved.
  /// Null inherits the deck colour; an empty string means none.
  final String? backgroundColor;

  /// Native tables, stacked in order below the bullets. Two at most: a third
  /// would leave each too small to read on a phone.
  final List<SlideTable> tables;

  /// One native chart, sharing the space below the bullets with tables.
  final SlideChart? chart;

  /// The single table older builds stored. Kept so their call sites and JSON
  /// keep working; [allTables] is what the app reads.
  final SlideTable? table;

  List<SlideTable> get allTables =>
      table == null ? tables : [table!, ...tables];
  static const maxTables = 2;
  static const maxNotesLength = 2000;

  /// Shapes layered on top of the title/bullets slots. Empty on a page built
  /// only with the standard layout.
  final List<SlideElement> elements;
  Map<String, dynamic> toJson() => {
    'title': title,
    'bullets': bullets,
    if (bulletLevels.any((level) => level != 0)) 'bulletLevels': bulletLevels,
    if (notes.isNotEmpty) 'notes': notes,
    if (imageId != null) 'imageId': imageId,
    if (backgroundImageId != null) 'backgroundImageId': backgroundImageId,
    if (backgroundColor != null) 'backgroundColor': backgroundColor,
    if (allTables.isNotEmpty)
      'tables': [for (final table in allTables) table.toJson()],
    if (chart != null) 'chart': chart!.toJson(),
    if (elements.isNotEmpty)
      'elements': [for (final element in elements) element.toJson()],
  };
  factory Slide.fromJson(Map<String, dynamic> j) => Slide(
    title: j['title'] as String? ?? '',
    bullets: List<String>.from(j['bullets'] as List? ?? []),
    bulletLevels: List<int>.from(j['bulletLevels'] as List? ?? []),
    notes: j['notes'] as String? ?? '',
    imageId: j['imageId'] as String?,
    backgroundImageId: j['backgroundImageId'] as String?,
    backgroundColor: j['backgroundColor'] as String?,
    // Builds before 0.2.2 stored one table under `table`.
    tables: [
      for (final table in j['tables'] as List? ?? [
        if (j['table'] != null) j['table'],
      ])
        SlideTable.fromJson(Map<String, dynamic>.from(table as Map)),
    ],
    chart: j['chart'] == null
        ? null
        : SlideChart.fromJson(Map<String, dynamic>.from(j['chart'] as Map)),
    elements: [
      for (final element in j['elements'] as List? ?? [])
        SlideElement.fromJson(Map<String, dynamic>.from(element as Map)),
    ],
  );
}

/// A bounded, rectangular text table. Deep copies prevent a caller from
/// mutating a validated table into a ragged or oversized one before export.
class SlideTable {
  factory SlideTable({
    required List<List<String>> rows,
    bool headerRow = true,
  }) {
    if (rows.isEmpty ||
        rows.length > maxRows ||
        rows.first.isEmpty ||
        rows.first.length > maxColumns) {
      throw const FormatException('invalidTable');
    }
    final columns = rows.first.length;
    for (final row in rows) {
      if (row.length != columns ||
          row.any((cell) => cell.length > maxCellLength)) {
        throw const FormatException('invalidTable');
      }
    }
    return SlideTable._(
      List<List<String>>.unmodifiable([
        for (final row in rows) List<String>.unmodifiable(row),
      ]),
      headerRow,
    );
  }

  const SlideTable._(this.rows, this.headerRow);

  static const maxRows = 12;
  static const maxColumns = 8;
  static const maxCellLength = 500;
  final List<List<String>> rows;
  final bool headerRow;
  int get columnCount => rows.first.length;

  Map<String, dynamic> toJson() => {'rows': rows, 'headerRow': headerRow};

  factory SlideTable.fromJson(Map<String, dynamic> json) {
    final rows = json['rows'];
    final headerRow = json['headerRow'] ?? true;
    if (rows is! List ||
        rows.isEmpty ||
        rows.length > maxRows ||
        headerRow is! bool) {
      throw const FormatException('invalidTable');
    }
    final cells = <List<String>>[];
    for (final row in rows) {
      if (row is! List ||
          row.isEmpty ||
          row.length > maxColumns ||
          row.any((cell) => cell is! String)) {
        throw const FormatException('invalidTable');
      }
      cells.add(List<String>.from(row));
    }
    return SlideTable(rows: cells, headerRow: headerRow);
  }
}

/// A bounded native chart on a slide. Values are doubles so the preview and
/// the exported chart draw exactly what validation accepted.
class SlideChart {
  factory SlideChart({
    String kind = 'bar',
    String title = '',
    required List<String> categories,
    required List<ChartSeries> series,
    bool dataLabels = false,
    String valueFormat = 'general',
    bool stacked = false,
  }) {
    if (!kinds.contains(kind) ||
        categories.isEmpty ||
        categories.length > maxCategories ||
        series.isEmpty ||
        series.length > maxSeries ||
        !valueFormats.contains(valueFormat)) {
      throw const FormatException('invalidChart');
    }
    final labels = <String>[];
    for (final category in categories) {
      final label = category.trim();
      if (label.isEmpty || label.length > maxLabelLength) {
        throw const FormatException('invalidChart');
      }
      labels.add(label);
    }
    for (final item in series) {
      if (item.values.length != labels.length) {
        throw const FormatException('invalidChart');
      }
    }
    return SlideChart._(
      kind,
      title.trim(),
      List<String>.unmodifiable(labels),
      List<ChartSeries>.unmodifiable(series),
      dataLabels,
      valueFormat,
      stacked,
    );
  }

  const SlideChart._(
    this.kind,
    this.title,
    this.categories,
    this.series,
    this.dataLabels,
    this.valueFormat,
    this.stacked,
  );

  static const kinds = ['bar', 'line', 'pie'];

  /// How a number reads on the page: plain, `0–100` percent, or grouped
  /// thousands. The stored values never change, only how they are printed.
  static const valueFormats = ['general', 'percent', 'thousand'];
  static const maxCategories = 12;
  static const maxSeries = 3;
  static const maxLabelLength = 40;

  final String kind;
  final String title;
  final List<String> categories;
  final List<ChartSeries> series;

  /// Print each value next to its bar, point or slice.
  final bool dataLabels;

  /// One of [valueFormats].
  final String valueFormat;

  /// Stack a bar chart's series instead of placing them side by side.
  /// Ignored by line and pie, which have no stacking.
  final bool stacked;

  /// The label drawn for [value], with no unit conversion — a `percent`
  /// chart is expected to carry values like `42`, not `0.42`.
  String formatValue(double value) {
    final rounded = value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    switch (valueFormat) {
      case 'percent':
        return '$rounded%';
      case 'thousand':
        final whole = value.round();
        final digits = whole.abs().toString();
        final grouped = StringBuffer();
        for (var i = 0; i < digits.length; i++) {
          if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
          grouped.write(digits[i]);
        }
        return '${whole < 0 ? '-' : ''}$grouped';
      default:
        return rounded;
    }
  }

  /// The DrawingML `formatCode` matching [valueFormat].
  String get numberFormatCode => switch (valueFormat) {
    'percent' => '0"%"',
    'thousand' => '#,##0',
    _ => 'General',
  };

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (title.isNotEmpty) 'title': title,
    'categories': categories,
    'series': [for (final item in series) item.toJson()],
    if (dataLabels) 'dataLabels': true,
    if (valueFormat != 'general') 'valueFormat': valueFormat,
    if (stacked) 'stacked': true,
  };

  factory SlideChart.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final title = json['title'] ?? '';
    final categories = json['categories'];
    final series = json['series'];
    final dataLabels = json['dataLabels'] ?? false;
    final valueFormat = json['valueFormat'] ?? 'general';
    final stacked = json['stacked'] ?? false;
    if (kind is! String ||
        title is! String ||
        categories is! List ||
        series is! List ||
        dataLabels is! bool ||
        valueFormat is! String ||
        stacked is! bool) {
      throw const FormatException('invalidChart');
    }
    final labels = <String>[];
    for (final category in categories) {
      if (category is! String) throw const FormatException('invalidChart');
      labels.add(category);
    }
    final parsed = <ChartSeries>[];
    for (final item in series) {
      if (item is! Map) throw const FormatException('invalidChart');
      final name = item['name'];
      final values = item['values'];
      if (name is! String ||
          values is! List ||
          values.any((value) => value is! num)) {
        throw const FormatException('invalidChart');
      }
      parsed.add(
        ChartSeries(
          name: name,
          values: [for (final value in values) (value as num).toDouble()],
        ),
      );
    }
    return SlideChart(
      kind: kind,
      title: title,
      categories: labels,
      series: parsed,
      dataLabels: dataLabels,
      valueFormat: valueFormat,
      stacked: stacked,
    );
  }
}

/// One named series in a [SlideChart]. The value bounds keep the chart XML
/// valid and the preview's scaling finite for any model output.
class ChartSeries {
  factory ChartSeries({required String name, required List<double> values}) {
    final label = name.trim();
    if (label.length > SlideChart.maxLabelLength ||
        values.isEmpty ||
        values.any((value) => !value.isFinite || value.abs() > maxValue)) {
      throw const FormatException('invalidChart');
    }
    return ChartSeries._(label, List<double>.unmodifiable(values));
  }

  const ChartSeries._(this.name, this.values);

  static const maxValue = 1e9;

  final String name;
  final List<double> values;

  Map<String, dynamic> toJson() => {'name': name, 'values': values};
}

/// A deck being built. Held in memory for the session: the workspace reads the
/// same structure the tools write, so the preview cannot drift from the file.
class Deck {
  Deck({
    required this.id,
    required this.title,
    this.aspectRatio = '16:9',
    this.finished = false,
    this.backgroundImageId,
    this.backgroundColor,
    List<Slide>? slides,
  }) : slides = slides ?? [];
  final String id;
  String title;
  final String aspectRatio;
  final List<Slide> slides;

  /// The picture behind pages that do not name one of their own.
  String? backgroundImageId;

  /// The solid colour used when a page resolves no background picture.
  String? backgroundColor;

  /// Set once the model says the deck is complete, so the workspace can tell
  /// a deck still being written from one that will not change again.
  bool finished;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'aspectRatio': aspectRatio,
    'finished': finished,
    if (backgroundImageId != null) 'backgroundImageId': backgroundImageId,
    if (backgroundColor != null) 'backgroundColor': backgroundColor,
    'slides': [for (final slide in slides) slide.toJson()],
  };

  factory Deck.fromJson(Map<String, dynamic> json) => Deck(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    aspectRatio: json['aspectRatio'] as String? ?? '16:9',
    finished: json['finished'] == true,
    backgroundImageId: json['backgroundImageId'] as String?,
    backgroundColor: json['backgroundColor'] as String?,
    slides: [
      for (final slide in json['slides'] as List? ?? [])
        Slide.fromJson(Map<String, dynamic>.from(slide as Map)),
    ],
  );

  /// The background this page actually uses: its own override, otherwise the
  /// deck default. An empty override means deliberately no background.
  String? backgroundFor(Slide slide) {
    final own = slide.backgroundImageId;
    if (own != null) return own.isEmpty ? null : own;
    final shared = backgroundImageId;
    return shared == null || shared.isEmpty ? null : shared;
  }

  /// The solid colour a page falls back to when it has no background picture.
  String? backgroundColorFor(Slide slide) {
    final own = slide.backgroundColor;
    if (own != null) return own.isEmpty ? null : own;
    final shared = backgroundColor;
    return shared == null || shared.isEmpty ? null : shared;
  }
}

const createDeckTool = {
  'name': 'create_deck',
  'description':
      'Create an empty slide deck. Use this for presentations, not for a '
      'single picture: slides are text and images the user can still edit in '
      'PowerPoint or WPS afterwards. Pages can carry a picture: generate it '
      'with generate_image, then attach it through add_slide.image_id.',
  'parameters': {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'aspect_ratio': {
        'type': 'string',
        'enum': ['16:9', '4:3'],
      },
    },
    'required': ['title', 'aspect_ratio'],
    'additionalProperties': false,
  },
};

const addSlideTool = {
  'name': 'add_slide',
  'description':
      'Append one slide to a deck. Call it once per slide so the user sees '
      'each page arrive. When the page should show a picture, pass the image '
      'id returned by generate_image, or "last" for the newest image.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'title': {'type': 'string'},
      'bullets': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'bullet_levels': {
        'type': 'array',
        'items': {'type': 'integer', 'minimum': 0, 'maximum': 2},
        'description':
            'One indent level per bullet: 0 top, 1 sub-point, 2 detail. '
            'Missing entries are 0.',
      },
      'image_id': {
        'type': 'string',
        'description':
            'The image_id returned by generate_image, "last" for the newest '
            'image, or an empty string for a text-only page. Never put a '
            'description or a prompt here.',
      },
    },
    'required': ['deck', 'title', 'bullets', 'image_id'],
    'additionalProperties': false,
  },
};

const updateSlideTool = {
  'name': 'update_slide',
  'description': 'Replace the text of one slide, keeping its image and table.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'title': {'type': 'string'},
      'bullets': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'bullet_levels': {
        'type': 'array',
        'items': {'type': 'integer', 'minimum': 0, 'maximum': 2},
        'description':
            'One indent level per bullet: 0 top, 1 sub-point, 2 detail. '
            'Missing entries are 0.',
      },
    },
    'required': ['deck', 'index', 'title', 'bullets', 'bullet_levels'],
    'additionalProperties': false,
  },
};

const moveSlideTool = {
  'name': 'move_slide',
  'description':
      'Move one slide to another position in the deck. Both indexes are '
      'zero-based and refer to the order before the move; the moved slide '
      'then sits at the target index.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'from': {'type': 'integer'},
      'to': {'type': 'integer'},
    },
    'required': ['deck', 'from', 'to'],
    'additionalProperties': false,
  },
};

const removeSlideTool = {
  'name': 'remove_slide',
  'description': 'Remove one slide from a deck.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
    },
    'required': ['deck', 'index'],
    'additionalProperties': false,
  },
};

const addTableTool = {
  'name': 'add_table',
  'description':
      'Add or replace an editable text table on a slide. Use 1-12 '
      'rectangular rows with 1-8 columns and at most 500 characters per cell. '
      'A page holds up to two tables, stacked in call order; they share the '
      'space below the bullets, so keep both small. Set header_row to style '
      'the first row as a heading.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'table_index': {
        'type': 'integer',
        'description':
            '-1 appends a new table (zero, one or two). 0 or 1 replaces that '
            'existing table instead.',
      },
      'rows': {
        'type': 'array',
        'minItems': 1,
        'maxItems': SlideTable.maxRows,
        'items': {
          'type': 'array',
          'minItems': 1,
          'maxItems': SlideTable.maxColumns,
          'items': {'type': 'string', 'maxLength': SlideTable.maxCellLength},
        },
      },
      'header_row': {'type': 'boolean'},
    },
    'required': ['deck', 'index', 'table_index', 'rows', 'header_row'],
    'additionalProperties': false,
  },
};

const addChartTool = {
  'name': 'add_chart',
  'description':
      'Add or replace the chart on a slide. Bars, lines and pies stay native, '
      'editable charts in PowerPoint. Use 1-12 short categories and 1-3 '
      'series whose values match the categories. Calling add_chart again on '
      'the same page replaces its chart instead of stacking a second one. A '
      'pie chart draws only the first series. Set data_labels to print the '
      'numbers on the chart, value_format to read them as plain numbers, '
      'percent (values written 0-100) or grouped thousands, and stacked to '
      'pile bar series instead of placing them side by side.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'kind': {'type': 'string', 'enum': SlideChart.kinds},
      'title': {
        'type': 'string',
        'description': 'Chart title; an empty string leaves it out.',
      },
      'categories': {
        'type': 'array',
        'minItems': 1,
        'maxItems': SlideChart.maxCategories,
        'items': {'type': 'string', 'maxLength': SlideChart.maxLabelLength},
      },
      'series': {
        'type': 'array',
        'minItems': 1,
        'maxItems': SlideChart.maxSeries,
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'maxLength': SlideChart.maxLabelLength},
            'values': {
              'type': 'array',
              'minItems': 1,
              'maxItems': SlideChart.maxCategories,
              'items': {'type': 'number'},
            },
          },
          'required': ['name', 'values'],
          'additionalProperties': false,
        },
      },
      'data_labels': {
        'type': 'boolean',
        'description': 'Print each value on its bar, point or slice.',
      },
      'value_format': {
        'type': 'string',
        'enum': SlideChart.valueFormats,
        'description':
            'How values read: plain numbers, percent (write 42, not 0.42) or '
            'grouped thousands.',
      },
      'stacked': {
        'type': 'boolean',
        'description':
            'Pile bar series on top of each other instead of side by side. '
            'Ignored by line and pie.',
      },
    },
    'required': [
      'deck',
      'index',
      'kind',
      'title',
      'categories',
      'series',
      'data_labels',
      'value_format',
      'stacked',
    ],
    'additionalProperties': false,
  },
};

const setNotesTool = {
  'name': 'set_notes',
  'description':
      'Set the speaker notes of one slide. Notes are saved in the .pptx notes '
      'page and shown under the page in the workspace; they never appear on '
      'the slide itself. Pass an empty string to clear them.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'notes': {'type': 'string', 'maxLength': Slide.maxNotesLength},
    },
    'required': ['deck', 'index', 'notes'],
    'additionalProperties': false,
  },
};

const finishDeckTool = {
  'name': 'finish_deck',
  'description':
      'Finish a deck once every slide is in place. Report the slide count.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
    },
    'required': ['deck'],
    'additionalProperties': false,
  },
};

const setBackgroundTool = {
  'name': 'set_background',
  'description':
      'Put a generated picture behind the text of one page or the whole deck. '
      'Generate a low-contrast background with generate_image first, then pass '
      'its image_id (or "last"). index -1 sets the deck background used by '
      'every page without its own; a zero-based index sets that page only. '
      'An empty image_id clears it. The app lays a light scrim over the '
      'picture so editable text stays readable.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'image_id': {
        'type': 'string',
        'description':
            'The image_id returned by generate_image, "last" for the newest '
            'image, or an empty string to clear the background.',
      },
      'index': {
        'type': 'integer',
        'description': 'Zero-based slide index, or -1 for the whole deck.',
      },
      'color': {
        'type': 'string',
        'description':
            'A solid RRGGBB page colour. Pass an empty string for none. A '
            'non-empty image_id wins over the colour.',
      },
    },
    'required': ['deck', 'image_id', 'index', 'color'],
    'additionalProperties': false,
  },
};

const addTextTool = {
  'name': 'add_text',
  'description':
      'Place an editable text box anywhere on a slide. Coordinates are '
      'fractions of the page: x and y are the top-left corner, width and '
      'height the box size, all between 0 and 1, and x+width / y+height must '
      'not exceed 1. Use this for free-form layouts, cover titles, captions, '
      'labels and stat callouts; use add_slide for the standard '
      'title-and-bullets page. font_size is in points and stays literal in '
      'PowerPoint. color, fill and border are RRGGBB hex strings; pass an '
      'empty string for no fill or border. align is left, center or right and '
      'radius curves the corners by 0 to 0.5 of the shorter side. The result '
      'names the element id for remove_element.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'text': {'type': 'string', 'maxLength': SlideElement.maxTextLength},
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'width': {'type': 'number'},
      'height': {'type': 'number'},
      'font_size': {'type': 'number'},
      'color': {'type': 'string'},
      'bold': {'type': 'boolean'},
      'align': {'type': 'string', 'enum': SlideElement.alignValues},
      'font': {
        'type': 'string',
        'description':
            'Typeface for this box, for example "Microsoft YaHei" or '
            '"Georgia". Pass an empty string for the theme font.',
      },
      'italic': {'type': 'boolean'},
      'padding': {
        'type': 'number',
        'description':
            'Point insets inside the box, 0-72. Zero uses a size-based '
            'default.',
      },
      'line_spacing': {
        'type': 'number',
        'description': 'Line height as a multiple of the font size, 0.7-3.',
      },
      'fill': {'type': 'string'},
      'fill2': {
        'type': 'string',
        'description':
            'Second gradient stop (RRGGBB). Set together with fill for a '
            'top-left to bottom-right gradient; empty keeps fill solid.',
      },
      'border': {'type': 'string'},
      'radius': {'type': 'number'},
      'shadow': {
        'type': 'boolean',
        'description': 'Soft drop shadow, for cards and callouts.',
      },
      'rotation': {
        'type': 'number',
        'description': 'Tilt in degrees, -45 to 45. Use sparingly.',
      },
      'letter_spacing': {
        'type': 'number',
        'description':
            'Extra space between characters in points, -2 to 20; widen short '
            'display words, leave body text at 0.',
      },
    },
    'required': [
      'deck',
      'index',
      'text',
      'x',
      'y',
      'width',
      'height',
      'font_size',
      'color',
      'bold',
      'italic',
      'align',
      'font',
      'padding',
      'line_spacing',
      'fill',
      'fill2',
      'border',
      'radius',
      'shadow',
      'rotation',
      'letter_spacing',
    ],
    'additionalProperties': false,
  },
};

const updateTextTool = {
  'name': 'update_text',
  'description':
      'Change the words or styling of one text box that add_text created, '
      'keeping its position and size. Use the element id add_text returned. '
      'This is cheaper than remove_element plus a new add_text, and it keeps '
      'the box on the same layer. Every style field is sent each time; pass '
      'the current value to keep it.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'element': {'type': 'string'},
      'text': {'type': 'string', 'maxLength': SlideElement.maxTextLength},
      'font_size': {'type': 'number'},
      'color': {'type': 'string'},
      'bold': {'type': 'boolean'},
      'italic': {'type': 'boolean'},
      'align': {'type': 'string', 'enum': SlideElement.alignValues},
      'font': {'type': 'string'},
      'padding': {'type': 'number'},
      'line_spacing': {'type': 'number'},
      'fill': {'type': 'string'},
      'fill2': {
        'type': 'string',
        'description':
            'Second gradient stop (RRGGBB). Set together with fill for a '
            'top-left to bottom-right gradient; empty keeps fill solid.',
      },
      'border': {'type': 'string'},
      'radius': {'type': 'number'},
      'shadow': {'type': 'boolean'},
      'rotation': {'type': 'number'},
      'letter_spacing': {'type': 'number'},
    },
    'required': [
      'deck',
      'index',
      'element',
      'text',
      'font_size',
      'color',
      'bold',
      'italic',
      'align',
      'font',
      'padding',
      'line_spacing',
      'fill',
      'fill2',
      'border',
      'radius',
      'shadow',
      'rotation',
      'letter_spacing',
    ],
    'additionalProperties': false,
  },
};

const addImageTool = {
  'name': 'add_image',
  'description':
      'Place a generated picture anywhere on a slide, independently of the '
      'standard title/image layout. Generate it with generate_image first, '
      'then pass its image_id (or "last"). Coordinates are fractions of the '
      'page: x and y are the top-left corner, width and height the box size, '
      'all between 0 and 1, and x+width / y+height must not exceed 1. fit '
      'cover crops the picture to the box, contain keeps all of it and '
      'letterboxes it. Use several calls for a multi-image page. The result '
      'names the element id for remove_element.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'image_id': {
        'type': 'string',
        'description':
            'The image_id returned by generate_image, or "last" for the '
            'newest image. Never put a description or a prompt here.',
      },
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'width': {'type': 'number'},
      'height': {'type': 'number'},
      'fit': {'type': 'string', 'enum': SlideElement.fitValues},
      'radius': {'type': 'number'},
      'border': {'type': 'string'},
    },
    'required': [
      'deck',
      'index',
      'image_id',
      'x',
      'y',
      'width',
      'height',
      'fit',
      'radius',
      'border',
    ],
    'additionalProperties': false,
  },
};

const removeElementTool = {
  'name': 'remove_element',
  'description':
      'Remove one free-form element (text box or picture) from a slide, by the '
      'element id that add_text or add_image returned. The standard title, '
      'bullets and table are not elements; use update_slide or remove_slide.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
      'element': {'type': 'string'},
    },
    'required': ['deck', 'index', 'element'],
    'additionalProperties': false,
  },
};

const askUserTool = {
  'name': 'ask_user',
  'description':
      'Ask the user a question when you need a decision or a missing detail. '
      'The turn ends after this call and the user\'s next message is the '
      'answer. Provide short options when the choice is enumerable; pass an '
      'empty list otherwise. The app always adds a "type your own answer" '
      'choice, so never add such an option yourself. Put a recommended option '
      'first and mark it (Recommended).',
  'parameters': {
    'type': 'object',
    'properties': {
      'question': {'type': 'string'},
      'options': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': ['question', 'options'],
    'additionalProperties': false,
  },
};

/// Splits the stored `ask_user` tool result into the question and its options,
/// so the transcript can render them as buttons instead of one long line.
({String question, List<String> options}) askResult(String text) {
  final body = text.replaceFirst('Question for the user: ', '');
  final head = body.split(' The turn ends here;').first;
  final marker = head.indexOf(' Options: ');
  if (marker < 0) return (question: head.trim(), options: const []);
  final question = head.substring(0, marker).trim();
  var tail = head.substring(marker + ' Options: '.length).trim();
  if (tail.endsWith('.')) tail = tail.substring(0, tail.length - 1);
  return (
    question: question,
    options: tail
        .split(' / ')
        .map((option) => option.trim())
        .where((option) => option.isNotEmpty)
        .toList(),
  );
}

const fetchTool = {
  'name': 'fetch_url',
  'description':
      'Fetch one public http or https page and read it. Markdown is the '
      'default: headings, lists, links and code keep their shape. Use it only '
      'when the user gives a link or needs information that is not in the '
      'conversation. Loopback, private and link-local addresses are refused, '
      'and a long page is truncated.',
  'parameters': {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': 'Absolute http or https URL, including the scheme.',
      },
      'format': {
        'type': 'string',
        'enum': ['markdown', 'text'],
        'description':
            'Use markdown unless the user asks for the page as plain text; '
            'text drops headings, links and code fences.',
      },
    },
    'required': ['url', 'format'],
    'additionalProperties': false,
  },
};

/// Every tool offered to the model. The order is the order of the prompt.
const agentTools = [
  imageTool,
  listImagesTool,
  deleteImageTool,
  videoTool,
  fetchTool,
  createDeckTool,
  addSlideTool,
  addTextTool,
  updateTextTool,
  addImageTool,
  addTableTool,
  addChartTool,
  setBackgroundTool,
  updateSlideTool,
  moveSlideTool,
  setNotesTool,
  removeElementTool,
  removeSlideTool,
  finishDeckTool,
  askUserTool,
];
