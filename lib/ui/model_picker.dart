import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';

class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.studio,
    this.agent = false,
    this.video = false,
  });
  final Studio studio;
  final bool agent;
  final bool video;
  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  late final _model = TextEditingController(
    text: widget.video
        ? widget.studio.videoModel
        : widget.agent
        ? widget.studio.activeConfig.agentModel
        : widget.studio.activeConfig.imageModel,
  );
  final _filter = TextEditingController();
  StudioApi? _client;
  bool _loading = false;
  String? _error;
  late Set<String> _models = {
    _model.text,
    if (!widget.video)
      widget.agent
          ? widget.studio.config.agentModel
          : widget.studio.config.imageModel,
    if (widget.agent) ...widget.studio.config.agentProfiles.keys,
  }..remove('');

  @override
  void initState() {
    super.initState();
    // The server list is the source of truth; the built-in presets only fill
    // in parameter defaults. Ask for it as soon as the sheet opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetch();
    });
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = widget.studio.api;
    _client = client;
    try {
      final models = widget.video
          ? await client.listVideoModels()
          : await client.listModels(images: !widget.agent);
      if (mounted) {
        setState(() {
          _models = {..._models, ...models};
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              '${Strings.of(context).t(errorCode(e))}\n${errorDetailOf(e, secrets: [widget.studio.key, widget.studio.imageKey, widget.studio.videoKey]) ?? ''}',
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _client?.close();
    _model.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final models =
        _models
            .where(
              (model) =>
                  model.toLowerCase().contains(_filter.text.toLowerCase()),
            )
            .toList()
          ..sort();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              s.t(
                widget.video
                    ? 'videoModel'
                    : widget.agent
                    ? 'agentModel'
                    : 'imageModel',
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              s.t('modelSwitchNote'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('modelId'),
              controller: _model,
              decoration: InputDecoration(labelText: s.t('modelId')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filter,
                    decoration: InputDecoration(hintText: s.t('searchModels')),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                TextButton(
                  onPressed: _loading ? null : _fetch,
                  child: Text(s.t('checkModels')),
                ),
              ],
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(_error!, maxLines: 3, overflow: TextOverflow.ellipsis),
            Expanded(
              child: ListView.builder(
                itemCount: models.length,
                itemBuilder: (_, i) => ListTile(
                  title: Text(models[i]),
                  selected: _model.text == models[i],
                  onTap: () => setState(() => _model.text = models[i]),
                ),
              ),
            ),
            FilledButton(
              onPressed: _model.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, _model.text.trim()),
              child: Text(s.t('applyModel')),
            ),
          ],
        ),
      ),
    );
  }
}
