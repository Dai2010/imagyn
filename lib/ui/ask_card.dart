import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// One ask, rendered the way OpenCode's question dock does it: each option is
/// a radio row, the last row is always "type your own answer" and opens a
/// field, and a single button submits. An ask ends the turn here, so the
/// answer goes back as the user's next message.
class AskCard extends StatefulWidget {
  const AskCard({
    super.key,
    required this.question,
    required this.options,
    required this.onSubmit,
    this.enabled = true,
  });
  final String question;
  final List<String> options;
  final ValueChanged<String> onSubmit;
  final bool enabled;

  @override
  State<AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<AskCard> {
  final _answer = TextEditingController();
  int? _picked;
  bool _custom = false;
  bool _sent = false;

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _custom ? _answer.text.trim().isNotEmpty : _picked != null;

  void _submit() {
    if (!_canSubmit || _sent || !widget.enabled) return;
    final value = _custom ? _answer.text.trim() : widget.options[_picked!];
    setState(() => _sent = true);
    widget.onSubmit(value);
  }

  Widget _row({
    required Key key,
    required bool selected,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(8),
      onTap: widget.enabled && !_sent ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.help_outline,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.question,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < widget.options.length; i++)
              _row(
                key: ValueKey('askOption-$i'),
                selected: _picked == i && !_custom,
                label: widget.options[i],
                onTap: () => setState(() {
                  _picked = i;
                  _custom = false;
                }),
              ),
            _row(
              key: const ValueKey('askCustom'),
              selected: _custom,
              label: s.t('askCustomAnswer'),
              onTap: () => setState(() {
                _custom = true;
                _picked = null;
              }),
            ),
            if (_custom) ...[
              const SizedBox(height: 4),
              TextField(
                key: const ValueKey('askAnswer'),
                controller: _answer,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                enabled: !_sent,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: s.t('askCustomAnswer'),
                  isDense: true,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                key: const ValueKey('askSubmit'),
                onPressed: widget.enabled && !_sent && _canSubmit
                    ? _submit
                    : null,
                child: Text(s.t('askSubmit')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
