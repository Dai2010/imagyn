/// A way of drawing, expressed as words appended to the prompt.
///
/// Image endpoints have no negative-prompt field, so [avoid] is appended as an
/// "Avoid: …" line instead. That is a soft constraint: it shifts the model away
/// from its glossy default rather than forbidding anything outright, which is
/// why the built-in packs also name the finish they want in [words].
class ImageStyle {
  const ImageStyle({
    required this.id,
    required this.label,
    required this.words,
    this.avoid = '',
  });

  factory ImageStyle.custom({
    required String id,
    required String name,
    required String words,
    String avoid = '',
  }) {
    final label = name.trim();
    final body = words.trim();
    final skip = avoid.trim();
    if (id.trim().isEmpty ||
        label.isEmpty ||
        label.length > maxName ||
        body.isEmpty ||
        body.length > maxWords ||
        skip.length > maxAvoid) {
      throw const FormatException('invalidStyle');
    }
    return ImageStyle(id: id, label: label, words: body, avoid: skip);
  }

  static const maxName = 40;
  static const maxWords = 500;
  static const maxAvoid = 300;

  /// Stable identifier written into settings, deck records and tool calls.
  final String id;

  /// An l10n key for a built-in pack, the user's own name for a custom one.
  final String label;

  /// Words that describe the finish.
  final String words;

  /// What the picture should steer away from.
  final String avoid;

  bool get isBuiltIn => builtInStyles.any((style) => style.id == id);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': label,
    'words': words,
    if (avoid.isNotEmpty) 'avoid': avoid,
  };

  factory ImageStyle.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final words = json['words'];
    final avoid = json['avoid'] ?? '';
    if (id is! String || name is! String || words is! String || avoid is! String) {
      throw const FormatException('invalidStyle');
    }
    return ImageStyle.custom(id: id, name: name, words: words, avoid: avoid);
  }
}

/// Packs that ship with the app. Their labels are l10n keys.
const builtInStyles = [
  ImageStyle(
    id: 'cel',
    label: 'styleCel',
    words:
        'clean anime cel shading, crisp lineart, flat two-tone colors, '
        'matte finish, minimal gradients',
    avoid: 'glossy highlights, plastic skin, rim light, lens flare, '
        'bloom, 3D render',
  ),
  ImageStyle(
    id: 'painterly',
    label: 'stylePainterly',
    words: 'painterly brushwork, visible brush strokes, soft blended edges, '
        'matte canvas texture, muted palette',
    avoid: 'glossy highlights, airbrushed plastic skin, lens flare, HDR',
  ),
  ImageStyle(
    id: 'flat',
    label: 'styleFlat',
    words: 'flat vector illustration, geometric shapes, solid fills, '
        'no gradients, minimal detail',
    avoid: 'gradients, glossy highlights, 3D render, lens flare',
  ),
  ImageStyle(
    id: 'watercolor',
    label: 'styleWatercolor',
    words: 'watercolor wash, soft pigment blooms, paper grain, muted palette',
    avoid: 'glossy highlights, hard vector edges, 3D render, lens flare',
  ),
  ImageStyle(
    id: 'pixel',
    label: 'stylePixel',
    words: 'pixel art, 16-bit palette, hard pixel edges, limited colors',
    avoid: 'anti-aliasing, gradients, glossy highlights, 3D render',
  ),
  ImageStyle(
    id: 'film',
    label: 'styleFilm',
    words: '35mm film photograph, natural light, fine grain, '
        'soft contrast, muted colors',
    avoid: 'glossy CG render, plastic skin, lens flare, HDR',
  ),
];

/// The choices the Agent may name: `auto` plus every built-in id. Custom packs
/// are private to the device, so the model cannot ask for one by id.
const styleChoices = [
  'auto',
  'cel',
  'painterly',
  'flat',
  'watercolor',
  'pixel',
  'film',
];

/// Every id the Agent is allowed to send, without the `auto` marker.
const builtInStyleIds = ['cel', 'painterly', 'flat', 'watercolor', 'pixel', 'film'];

/// The style with [id], looked up among the built-ins and then [custom].
ImageStyle? styleById(Iterable<ImageStyle> custom, String id) {
  for (final style in builtInStyles) {
    if (style.id == id) return style;
  }
  for (final style in custom) {
    if (style.id == id) return style;
  }
  return null;
}

/// The words a pack contributes: the finish it asks for, and what to steer
/// away from. Kept separate from [withStyle] because the composer writes this
/// block into the prompt the user is editing.
String styleBlock(ImageStyle style) {
  final buffer = StringBuffer('Style: ${style.words}');
  if (style.avoid.isNotEmpty) buffer.write('\nAvoid: ${style.avoid}');
  return buffer.toString();
}

/// [prompt] with [style] written after it, or unchanged when there is none.
String withStyle(String prompt, ImageStyle? style) {
  if (style == null) return prompt;
  return '${prompt.trim()}\n\n${styleBlock(style)}';
}

/// The pack already written into [text], if any. The composer uses this to show
/// which style the current prompt carries, without keeping a second copy of the
/// choice that could drift from the text.
ImageStyle? styleIn(String text, Iterable<ImageStyle> custom) {
  for (final style in [...builtInStyles, ...custom]) {
    if (text.contains(styleBlock(style))) return style;
  }
  return null;
}

/// [text] with its trailing `/style …` command replaced by [style]'s block,
/// which the user can then read and edit like any other prompt text.
///
/// The command is the last line, so a prompt written first keeps its words.
String insertStyle(String text, ImageStyle style) {
  final lines = text.split('\n');
  final tail = lines.isEmpty ? '' : lines.last.trimLeft();
  final body = tail.startsWith('/style')
      ? lines.sublist(0, lines.length - 1).join('\n')
      : text;
  final rest = body.trim();
  final block = styleBlock(style);
  return rest.isEmpty ? block : '$rest\n\n$block';
}

/// [text] with [style]'s block taken back out again.
String removeStyle(String text, ImageStyle style) {
  final block = styleBlock(style);
  final index = text.indexOf(block);
  if (index < 0) return text;
  final before = text.substring(0, index).trimRight();
  final after = text.substring(index + block.length).trimLeft();
  if (before.isEmpty) return after;
  if (after.isEmpty) return before;
  return '$before\n\n$after';
}
