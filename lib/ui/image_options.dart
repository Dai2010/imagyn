import 'package:flutter/material.dart';

import '../core/models.dart';
import '../l10n/strings.dart';

class ImageOptionsSheet extends StatefulWidget {
  const ImageOptionsSheet({super.key, required this.options, this.model = ''});
  final ImageOptions options;
  final String model;
  @override
  State<ImageOptionsSheet> createState() => _ImageOptionsSheetState();
}

class _ImageOptionsSheetState extends State<ImageOptionsSheet> {
  late ImageOptions options = widget.options;
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

  /// The presets mirror the reference implementation's 1K tier: a ratio with the
  /// exact pixels handed to the API, so what is chosen and what is sent cannot
  /// drift apart. `auto` is kept because it is what the service resolves itself.
  static const _sizePresets = <String, String>{
    'auto': '',
    '1024x1024': '1:1',
    '1536x1024': '3:2',
    '1024x1536': '2:3',
    '1280x720': '16:9',
    '720x1280': '9:16',
    '1024x768': '4:3',
    '768x1024': '3:4',
    '1280x544': '21:9',
  };

  String _sizeLabel(String value) {
    if (value == 'auto') return s.t('auto');
    final ratio = _sizePresets[value];
    return ratio == null || ratio.isEmpty ? value : '$ratio · $value';
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
                        ..._sizePresets.keys,
                        // A size saved by an older build stays selectable rather
                        // than being silently replaced.
                        if (!_sizePresets.containsKey(options.size)) options.size,
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
                ],
              );
            },
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
