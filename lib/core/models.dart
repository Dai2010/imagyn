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

const deckAgentPrompt =
    'You are Imagyn, an assistant for images and slide decks. Reply in the user language. '
    'Use generate_image only for an explicit image request or when a deck page needs a picture; '
    'never claim an image was generated yourself. '
    'For a presentation, deck, PPT or slides request, build it with the deck tools: '
    'create_deck, then add_slide once per page, then finish_deck. A deck is editable text and '
    'pictures, not a picture of a slide. generate_image returns an image_id: pass that exact id '
    'as add_slide.image_id (or pass "last" for the newest image) so the page really carries the '
    'picture. Never put a description or a prompt into image_id. '
    'You may call tools repeatedly in one turn; after each result decide the next step and keep '
    'going until the deck is finished, then answer briefly. '
    'If a tool returns an error, read its code: retry only with changed arguments, change '
    'approach, or ask the user with ask_user. Never repeat the same failing call. '
    'Call ask_user when you need a decision or a missing detail; the turn ends and the user\'s '
    'next message is the answer. '
    'For discussions reply in text. Reference images are ordered and supplied by the app; '
    'preserve user constraints on edits. If the target is unclear, ask. '
    'When the user asks for a shape or aspect ratio, pass it as aspect_ratio; never express the '
    'ratio only in the prompt text.';

const tableAgentPrompt =
    '$deckAgentPrompt '
    'For tabular data, call add_table after add_slide with the zero-based slide '
    'index, rectangular string rows, and header_row. This creates editable '
    'table cells. Each slide holds one table; add_table replaces that table. '
    'Keep cells concise and split large tables across slides.';

/// Shipped with the app and never edited by the user: it only explains the
/// tools. A build that adds a tool adds its instructions here, so the model
/// cannot lose them by rewriting the user-facing prompt.
const builtInAgentPrompt =
    '$tableAgentPrompt '
    'A page can carry a full-bleed picture behind its text. Generate a '
    'low-contrast background with generate_image (16:9 for a 16:9 deck), then '
    'call set_background with the deck id, that image_id (or "last"), and '
    'index -1 for every page or a zero-based page index for one page. The app '
    'adds a light scrim, so avoid busy backgrounds that fight the text. '
    'A page can also hold free-form elements: add_text places a styled, '
    'editable text box and add_image places a generated picture, both at '
    'fractional page coordinates, so one page can carry several pictures, '
    'captions and decoration instead of the default title-and-picture slots. '
    'The exported page is light (near-white), so default to dark text unless '
    'you set a fill. Build a cover, a multi-image grid or a poster page that '
    'way; every element is a real PowerPoint shape the user can still edit, '
    'and remove_element deletes one by the id the tool returned.';

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

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'assetIds': assetIds,
    if (model != null) 'model': model,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (calls.isNotEmpty) 'calls': calls.map((call) => call.toJson()).toList(),
    if (callId != null) 'callId': callId,
    if (name != null) 'name': name,
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
    },
    'required': ['prompt', 'aspect_ratio'],
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
    String align = 'left',
    String? fill,
    String? border,
    double radius = 0,
    String fit = 'cover',
  }) {
    // Models habitually write `#RRGGBB` although the schema says RRGGBB;
    // accepting the prefix is cheaper than answering with an error.
    String? rgb(String? value) => value == null
        ? null
        : (value.startsWith('#') ? value.substring(1) : value);
    final ink = rgb(color);
    final fillRgb = rgb(fill);
    final borderRgb = rgb(border);
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
        !alignValues.contains(align) ||
        !fitValues.contains(fit) ||
        !_isHexColor(ink!) ||
        (fillRgb != null && !_isHexColor(fillRgb)) ||
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
      align: align,
      fill: fillRgb?.toUpperCase(),
      border: borderRgb?.toUpperCase(),
      radius: radius,
      fit: fit,
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
    required this.align,
    required this.fill,
    required this.border,
    required this.radius,
    required this.fit,
  });

  /// Enough shapes to build a poster-like page, few enough that the model
  /// cannot turn a slide into a thousand-element document.
  static const maxCount = 12;
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
  final String align;

  /// `RRGGBB` or null for no fill; a text box's background and outline.
  final String? fill;
  final String? border;

  /// Corner curve as a fraction of the shorter side, 0..0.5.
  final double radius;

  /// How a picture fills its box: `cover` crops, `contain` letterboxes.
  final String fit;

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
    'align': align,
    if (fill != null) 'fill': fill,
    if (border != null) 'border': border,
    'radius': radius,
    'fit': fit,
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
    align: j['align'] as String? ?? 'left',
    fill: j['fill'] as String?,
    border: j['border'] as String?,
    radius: (j['radius'] as num? ?? 0).toDouble(),
    fit: j['fit'] as String? ?? 'cover',
  );
}

/// One slide: what a deck tool adds, and what the workspace renders.
class Slide {
  const Slide({
    this.title = '',
    this.bullets = const [],
    this.imageId,
    this.backgroundImageId,
    this.table,
    this.elements = const [],
  });
  final String title;
  final List<String> bullets;
  final String? imageId;

  /// A picture behind the whole page. Null inherits the deck background; an
  /// empty string means this page has none even when the deck has one.
  final String? backgroundImageId;
  final SlideTable? table;

  /// Shapes layered on top of the title/bullets slots. Empty on a page built
  /// only with the standard layout.
  final List<SlideElement> elements;
  Map<String, dynamic> toJson() => {
    'title': title,
    'bullets': bullets,
    if (imageId != null) 'imageId': imageId,
    if (backgroundImageId != null) 'backgroundImageId': backgroundImageId,
    if (table != null) 'table': table!.toJson(),
    if (elements.isNotEmpty)
      'elements': [for (final element in elements) element.toJson()],
  };
  factory Slide.fromJson(Map<String, dynamic> j) => Slide(
    title: j['title'] as String? ?? '',
    bullets: List<String>.from(j['bullets'] as List? ?? []),
    imageId: j['imageId'] as String?,
    backgroundImageId: j['backgroundImageId'] as String?,
    table: j['table'] == null
        ? null
        : SlideTable.fromJson(Map<String, dynamic>.from(j['table'] as Map)),
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

/// A deck being built. Held in memory for the session: the workspace reads the
/// same structure the tools write, so the preview cannot drift from the file.
class Deck {
  Deck({
    required this.id,
    required this.title,
    this.aspectRatio = '16:9',
    this.finished = false,
    this.backgroundImageId,
    List<Slide>? slides,
  }) : slides = slides ?? [];
  final String id;
  String title;
  final String aspectRatio;
  final List<Slide> slides;

  /// The picture behind pages that do not name one of their own.
  String? backgroundImageId;

  /// Set once the model says the deck is complete, so the workspace can tell
  /// a deck still being written from one that will not change again.
  bool finished;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'aspectRatio': aspectRatio,
    'finished': finished,
    if (backgroundImageId != null) 'backgroundImageId': backgroundImageId,
    'slides': [for (final slide in slides) slide.toJson()],
  };

  factory Deck.fromJson(Map<String, dynamic> json) => Deck(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    aspectRatio: json['aspectRatio'] as String? ?? '16:9',
    finished: json['finished'] == true,
    backgroundImageId: json['backgroundImageId'] as String?,
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
    },
    'required': ['deck', 'index', 'title', 'bullets'],
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
      'Add or replace the editable text table on an existing slide. Each slide '
      'holds one table. Use 1-12 rectangular rows with 1-8 columns and at most '
      '500 characters per cell. Keep text concise; split dense data across '
      'slides. Set header_row to style the first row as a heading.',
  'parameters': {
    'type': 'object',
    'properties': {
      'deck': {'type': 'string'},
      'index': {'type': 'integer', 'description': 'Zero-based slide index.'},
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
    'required': ['deck', 'index', 'rows', 'header_row'],
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
    },
    'required': ['deck', 'image_id', 'index'],
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
      'fill': {'type': 'string'},
      'border': {'type': 'string'},
      'radius': {'type': 'number'},
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
      'align',
      'fill',
      'border',
      'radius',
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
      'empty list otherwise.',
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

/// Every tool offered to the model. The order is the order of the prompt.
const agentTools = [
  imageTool,
  createDeckTool,
  addSlideTool,
  addTextTool,
  addImageTool,
  addTableTool,
  setBackgroundTool,
  updateSlideTool,
  removeElementTool,
  removeSlideTool,
  finishDeckTool,
  askUserTool,
];
