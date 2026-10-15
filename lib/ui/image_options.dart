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
  }) => DropdownButtonFormField<String>(
    key: ValueKey('$label-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: s.t(label)),
    items: values
        .map(
          (v) =>
              DropdownMenuItem(value: v, child: Text(translate ? s.t(v) : v)),
        )
        .toList(),
    onChanged: (v) => setState(() => update(v!)),
  );

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
                    child: _select('size', options.size, [
                      'auto',
                      '1024x1024',
                      '1536x1024',
                      '1024x1536',
                      if (![
                        'auto',
                        '1024x1024',
                        '1536x1024',
                        '1024x1536',
                      ].contains(options.size))
                        options.size,
                    ], (v) => options = options.copyWith(size: v)),
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
