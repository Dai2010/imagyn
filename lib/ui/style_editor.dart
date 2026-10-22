import 'package:flutter/material.dart';

import '../core/styles.dart';
import '../l10n/strings.dart';

/// Names the user gives their own packs, plus the words each one adds.
///
/// Returns the list as it stands after the dialog closes, so the caller can
/// offer a pack that was just created without waiting for a rebuild.
class StyleEditorDialog extends StatefulWidget {
  const StyleEditorDialog({
    super.key,
    required this.styles,
    this.onSave,
    this.onRemove,
  });

  final List<ImageStyle> styles;
  final Future<void> Function(ImageStyle style)? onSave;
  final Future<void> Function(String id)? onRemove;

  @override
  State<StyleEditorDialog> createState() => _StyleEditorDialogState();
}

class _StyleEditorDialogState extends State<StyleEditorDialog> {
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
