import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/studio.dart';
import '../core/styles.dart';
import '../core/video.dart';
import '../l10n/strings.dart';
import 'model_picker.dart';
import 'visuals.dart';

/// Video generation lives on a screen of its own rather than in the Gallery or
/// the Agent: a clip is a task that is polled for minutes, and both of those
/// pages would have to grow a second mode to host it.
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.studio,
    this.embedded = false,
  });
  final Studio studio;
  final bool embedded;

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
  Strings get s => Strings.of(context);

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

  /// Opens the same model sheet the Agent and image pages use, pointed at the
  /// video service: its `/models` list is the source of truth, the built-in
  /// presets are only a parameter reference.
  Future<void> _pickModel() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ModelPicker(studio: studio, video: true),
    );
    if (chosen == null || !mounted) return;
    setState(() => _model.text = chosen);
    await studio.setVideoModel(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = Theme.of(context);
    final body = ListenableBuilder(
      listenable: studio,
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              DecoratedBox(
                decoration: StudioVisuals.glass(context),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _prompt,
                        minLines: 2,
                        maxLines: 5,
                        decoration: InputDecoration(
                          hintText: s.t('prompt'),
                        ),
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
                            onSelected: (_) =>
                                _update(_options.copyWith(style: '')),
                          ),
                          for (final style in [
                            ...builtInStyles,
                            ...studio.customStyles,
                          ])
                            ChoiceChip(
                              key: ValueKey('videoStyle-${style.id}'),
                              label: Text(
                                style.isBuiltIn
                                    ? s.t(style.label)
                                    : style.label,
                              ),
                              selected: _options.style == style.id,
                              onSelected: (_) => _update(
                                _options.copyWith(style: style.id),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: StudioVisuals.glass(context),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        key: const ValueKey('videoModelPick'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: studio.busy ? null : _pickModel,
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: s.t('videoModel'),
                            suffixIcon: const Icon(Icons.expand_more_rounded),
                          ),
                          child: Text(
                            _model.text.trim().isEmpty
                                ? s.t('videoModel')
                                : _model.text.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('videoPath'),
                        controller: _path,
                        decoration: InputDecoration(
                          labelText: s.t('videoPath'),
                          hintText: 'videos',
                        ),
                      ),
                      const SizedBox(height: 18),
                      _label(s.t('videoRatio')),
                      _choices(
                        values: VideoOptions.ratios,
                        selected: _options.ratio,
                        onPick: (value) =>
                            _update(_options.copyWith(ratio: value)),
                      ),
                      const SizedBox(height: 14),
                      _label(s.t('videoResolution')),
                      _choices(
                        values: VideoOptions.resolutions,
                        selected: _options.resolution,
                        onPick: (value) =>
                            _update(_options.copyWith(resolution: value)),
                      ),
                      const SizedBox(height: 14),
                      _label(s.t('videoDuration')),
                      _choices(
                        values: const ['3', '5', '8', '10', '12'],
                        selected: '${_options.seconds}',
                        suffix: s.t('videoSecondsUnit'),
                        onPick: (value) => _update(
                          _options.copyWith(seconds: int.parse(value)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SwitchListTile(
                        key: const ValueKey('videoWatermark'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.t('videoWatermark')),
                        value: _options.watermark,
                        onChanged: (value) =>
                            _update(_options.copyWith(watermark: value)),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: FilledButton.icon(
                          key: const ValueKey('submitVideo'),
                          onPressed: studio.busy ? null : _submit,
                          icon: const Icon(Icons.movie_creation_outlined),
                          label: Text(s.t('create')),
                        ),
                      ),
                      if (studio.busy && !widget.embedded) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(s.t('working')),
                      ],
                      if (studio.error != null && !widget.embedded) ...[
                        const SizedBox(height: 12),
                        Text(
                          s.t(studio.error!),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        if (studio.errorDetail != null)
                          SelectableText(
                            studio.errorDetail!,
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _label(s.t('video')),
              if (studio.videos.isEmpty)
                DecoratedBox(
                  decoration: StudioVisuals.glass(context),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        s.t('videoEmpty'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              for (final asset in studio.videos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DecoratedBox(
                    decoration: StudioVisuals.glass(context, radius: 12),
                    child: ListTile(
                      key: ValueKey('video-${asset.id}'),
                      leading: Icon(
                        Icons.play_circle_outline_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(
                        asset.prompt.isEmpty ? asset.id : asset.prompt,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${asset.parameters['resolution'] ?? ''} · '
                        '${asset.parameters['ratio'] ?? ''} · '
                        '${asset.parameters['seconds'] ?? ''}${s.t('videoSecondsUnit')}',
                      ),
                      trailing: IconButton(
                        tooltip: s.t('videoSave'),
                        onPressed: _saving ? null : () => _save(asset),
                        icon: const Icon(Icons.download_rounded),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('video'))),
      body: body,
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _choices({
    required List<String> values,
    required String selected,
    required ValueChanged<String> onPick,
    String suffix = '',
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final value in values)
        ChoiceChip(
          key: ValueKey('videoChoice-$value'),
          label: Text('$value$suffix'),
          selected: selected == value,
          onSelected: (_) => onPick(value),
        ),
    ],
  );
}
