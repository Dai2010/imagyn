import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/studio.dart';
import '../core/styles.dart';
import '../core/video.dart';
import '../l10n/strings.dart';

/// Video generation lives on a screen of its own rather than in the Gallery or
/// the Agent: a clip is a task that is polled for minutes, and both of those
/// pages would have to grow a second mode to host it.
class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.studio});
  final Studio studio;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final _prompt = TextEditingController();
  late final _model = TextEditingController(text: widget.studio.videoModel);
  late final _path = TextEditingController(text: widget.studio.videoPath);
  late VideoOptions _options = widget.studio.videoOptions;
  bool _saving = false;

  Studio get studio => widget.studio;

  @override
  void dispose() {
    _prompt.dispose();
    _model.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    await studio.setVideoModel(_model.text);
    await studio.setVideoPath(_path.text);
    try {
      await studio.submitVideo(_prompt.text.trim(), _options);
      if (mounted && studio.error == null) _prompt.clear();
    } on FormatException {
      // The panel below already shows the studio's error.
    }
  }

  Future<void> _update(VideoOptions value) async {
    setState(() => _options = value);
    await studio.setVideoOptions(value);
  }

  Future<void> _save(Asset asset) async {
    setState(() => _saving = true);
    try {
      await studio.export(asset);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('video'))),
      body: ListenableBuilder(
        listenable: studio,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            TextField(
              controller: _prompt,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(hintText: s.t('prompt')),
            ),
            const SizedBox(height: 16),
            _label(s.t('style')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('videoStyleNone'),
                  label: Text(s.t('styleNone')),
                  selected: _options.style.isEmpty,
                  onSelected: (_) => _update(_options.copyWith(style: '')),
                ),
                for (final style in [...builtInStyles, ...studio.customStyles])
                  ChoiceChip(
                    key: ValueKey('videoStyle-${style.id}'),
                    label: Text(
                      style.isBuiltIn ? s.t(style.label) : style.label,
                    ),
                    selected: _options.style == style.id,
                    onSelected: (_) =>
                        _update(_options.copyWith(style: style.id)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _label(s.t('videoModel')),
            TextField(
              key: const ValueKey('videoModel'),
              controller: _model,
              decoration: const InputDecoration(hintText: 'seedance-1-0-pro'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final model in videoModels)
                  ChoiceChip(
                    label: Text(model.label),
                    selected: _model.text.trim() == model.id,
                    onSelected: (_) => setState(() => _model.text = model.id),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('videoPath'),
              controller: _path,
              decoration: InputDecoration(
                labelText: s.t('videoPath'),
                hintText: 'videos',
              ),
            ),
            const SizedBox(height: 16),
            _label(s.t('videoRatio')),
            _choices(
              values: VideoOptions.ratios,
              selected: _options.ratio,
              onPick: (value) => _update(_options.copyWith(ratio: value)),
            ),
            const SizedBox(height: 12),
            _label(s.t('videoResolution')),
            _choices(
              values: VideoOptions.resolutions,
              selected: _options.resolution,
              onPick: (value) => _update(_options.copyWith(resolution: value)),
            ),
            const SizedBox(height: 12),
            _label(s.t('videoDuration')),
            _choices(
              values: const ['3', '5', '8', '10', '12'],
              selected: '${_options.seconds}',
              onPick: (value) =>
                  _update(_options.copyWith(seconds: int.parse(value))),
            ),
            SwitchListTile(
              key: const ValueKey('videoWatermark'),
              contentPadding: EdgeInsets.zero,
              title: Text(s.t('videoWatermark')),
              value: _options.watermark,
              onChanged: (value) =>
                  _update(_options.copyWith(watermark: value)),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('submitVideo'),
              onPressed: studio.busy ? null : _submit,
              icon: const Icon(Icons.movie_creation_outlined),
              label: Text(s.t('create')),
            ),
            if (studio.busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(s.t('working')),
            ],
            if (studio.error != null) ...[
              const SizedBox(height: 12),
              Text(
                s.t(studio.error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              if (studio.errorDetail != null)
                SelectableText(
                  studio.errorDetail!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            const SizedBox(height: 24),
            _label(s.t('video')),
            if (studio.videos.isEmpty)
              Text(s.t('videoEmpty'), style: Theme.of(context).textTheme.bodySmall),
            for (final asset in studio.videos)
              ListTile(
                key: ValueKey('video-${asset.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.play_circle_outline),
                title: Text(
                  asset.prompt.isEmpty ? asset.id : asset.prompt,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${asset.parameters['resolution'] ?? ''} · '
                  '${asset.parameters['ratio'] ?? ''} · '
                  '${asset.parameters['seconds'] ?? ''}s',
                ),
                trailing: IconButton(
                  tooltip: s.t('videoSave'),
                  onPressed: _saving ? null : () => _save(asset),
                  icon: const Icon(Icons.download_rounded),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );

  Widget _choices({
    required List<String> values,
    required String selected,
    required ValueChanged<String> onPick,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final value in values)
        ChoiceChip(
          key: ValueKey('videoChoice-$value'),
          label: Text(value),
          selected: selected == value,
          onSelected: (_) => onPick(value),
        ),
    ],
  );
}
