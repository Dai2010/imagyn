import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/styles.dart';
import '../l10n/strings.dart';

class ImageOptionsSheet extends StatefulWidget {
  const ImageOptionsSheet({
    super.key,
    required this.options,
    this.model = '',
    this.styles = const [],
    this.onSaveStyle,
    this.onRemoveStyle,
  });
  final ImageOptions options;
  final String model;

  /// The packs the user wrote; the built-ins are always offered.
  final List<ImageStyle> styles;
  final Future<void> Function(ImageStyle style)? onSaveStyle;
  final Future<void> Function(String id)? onRemoveStyle;
  @override
  State<ImageOptionsSheet> createState() => _ImageOptionsSheetState();
}

class _ImageOptionsSheetState extends State<ImageOptionsSheet> {
  late ImageOptions options = widget.options;
  // Kept locally so a pack created in this sheet is selectable before the
  // parent rebuilds with the new list.
  late List<ImageStyle> _styles = List<ImageStyle>.of(widget.styles);
  Strings get s => Strings.of(context);

  Widget _select(
    String label,
    String value,
    List<String> values,
    ValueChanged<String> update, {
    bool translate = true,
    String Function(String value)? labelOf,
  }) => DropdownButtonFormField<String>(
    key: ValueKey('$label-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: s.t(label)),
    items: values
        .map(
          (v) => DropdownMenuItem(
            value: v,
            child: Text(
              labelOf != null ? labelOf(v) : (translate ? s.t(v) : v),
            ),
          ),
        )
        .toList(),
    onChanged: (v) => setState(() => update(v!)),
  );

  /// Sizes are chosen by ratio; `sizePresets` is what turns that choice into the
  /// pixels the API understands. `auto` is kept because it is what the service
  /// resolves itself.
  String _sizeLabel(String value) {
    if (value == 'auto') return s.t('auto');
    return ratioOfSize(value) ?? value;
  }

  /// Built-in packs carry an l10n key; the user's own packs carry their name.
  String _styleLabel(String value) {
    if (value.isEmpty) return s.t('styleNone');
    final style = styleById(_styles, value);
    if (style == null) return value;
    return style.isBuiltIn ? s.t(style.label) : style.label;
  }

  Future<void> _editStyles() async {
    final result = await showDialog<List<ImageStyle>>(
      context: context,
      builder: (context) => _StyleEditor(
        styles: _styles,
        onSave: widget.onSaveStyle,
        onRemove: widget.onRemoveStyle,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _styles = result;
      // A pack deleted while it was selected must not stay on the dropdown.
      if (options.style.isNotEmpty &&
          styleById(_styles, options.style) == null) {
        options = options.copyWith(style: '');
      }
    });
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .85,
    ),
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.t('imageParameters'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 16,
                children: [
                  SizedBox(
                    width: width,
                    child: _select(
                      'size',
                      options.size,
                      [
                        'auto',
                        ...sizePresets.values,
                        // A size saved by an older build stays selectable rather
                        // than being silently replaced.
                        if (options.size != 'auto' &&
                            !sizePresets.containsValue(options.size))
                          options.size,
                      ],
                      (v) => options = options.copyWith(size: v),
                      labelOf: _sizeLabel,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _select('quality', options.quality, [
                      'auto',
                      'low',
                      'medium',
                      'high',
                      if (widget.model.toLowerCase().contains(
                            'gpt-image-2.5',
                          ) ||
                          ['xhigh', 'max'].contains(options.quality)) ...[
                        'xhigh',
                        'max',
                      ],
                    ], (v) => options = options.copyWith(quality: v)),
                  ),
                  SizedBox(
                    width: width,
                    child: _select(
                      'outputFormat',
                      options.format,
                      ['png', 'jpeg', 'webp'],
                      (v) => options = options.copyWith(
                        format: v,
                        transparent: v == 'jpeg' ? false : options.transparent,
                      ),
                      translate: false,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _select(
                      'transparentBackground',
                      options.transparent ? 'on' : 'off',
                      options.format == 'jpeg' ? ['off'] : ['off', 'on'],
                      (v) => options = options.copyWith(transparent: v == 'on'),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _select('moderation', options.moderation, [
                      'auto',
                      'low',
                    ], (v) => options = options.copyWith(moderation: v)),
                  ),
                  SizedBox(
                    width: width,
                    child: _select(
                      'count',
                      '${options.count}',
                      List.generate(10, (i) => '${i + 1}'),
                      (v) => options = options.copyWith(count: int.parse(v)),
                      translate: false,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _select(
                      'style',
                      options.style,
                      [
                        '',
                        for (final style in builtInStyles) style.id,
                        for (final style in _styles) style.id,
                        // A deleted pack must not leave the dropdown showing a
                        // value it cannot offer.
                        if (options.style.isNotEmpty &&
                            styleById(_styles, options.style) == null)
                          options.style,
                      ],
                      (v) => options = options.copyWith(style: v),
                      labelOf: _styleLabel,
                    ),
                  ),
                ],
              );
            },
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('editStyles'),
              onPressed: _editStyles,
              icon: const Icon(Icons.brush_outlined, size: 18),
              label: Text(s.t('customStyles')),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            s.t('imageParametersNote'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.pop(context, options),
            child: Text(s.t('done')),
          ),
        ],
      ),
    ),
  );
}

/// Names the user gives their own packs, plus the words each one adds.
class _StyleEditor extends StatefulWidget {
  const _StyleEditor({
    required this.styles,
    this.onSave,
    this.onRemove,
  });

  final List<ImageStyle> styles;
  final Future<void> Function(ImageStyle style)? onSave;
  final Future<void> Function(String id)? onRemove;

  @override
  State<_StyleEditor> createState() => _StyleEditorState();
}

class _StyleEditorState extends State<_StyleEditor> {
  final _name = TextEditingController();
  final _words = TextEditingController();
  final _avoid = TextEditingController();
  late final List<ImageStyle> _styles = List<ImageStyle>.of(widget.styles);
  String? _error;
  bool _busy = false;

  Strings get s => Strings.of(context);

  @override
  void dispose() {
    _name.dispose();
    _words.dispose();
    _avoid.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final save = widget.onSave;
    if (save == null) return;
    final ImageStyle style;
    try {
      style = ImageStyle.custom(
        id: 'c${DateTime.now().microsecondsSinceEpoch}',
        name: _name.text,
        words: _words.text,
        avoid: _avoid.text,
      );
    } on FormatException {
      setState(() => _error = s.t('styleInvalid'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await save(style);
    if (!mounted) return;
    _styles.add(style);
    Navigator.pop(context, _styles);
  }

  Future<void> _remove(String id) async {
    await widget.onRemove?.call(id);
    if (!mounted) return;
    setState(() => _styles.removeWhere((style) => style.id == id));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(s.t('customStyles')),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('styleName'),
              controller: _name,
              decoration: InputDecoration(labelText: s.t('styleName')),
              maxLength: ImageStyle.maxName,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('styleWords'),
              controller: _words,
              decoration: InputDecoration(labelText: s.t('styleWords')),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('styleAvoid'),
              controller: _avoid,
              decoration: InputDecoration(labelText: s.t('styleAvoid')),
              minLines: 1,
              maxLines: 3,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('saveStyle'),
              onPressed: _busy ? null : _save,
              child: Text(s.t('styleSave')),
            ),
            if (_styles.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final style in _styles)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(style.label),
                  subtitle: Text(
                    style.words,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: s.t('styleDelete'),
                    onPressed: () => _remove(style.id),
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, _styles),
        child: Text(s.t('close')),
      ),
    ],
  );
}
