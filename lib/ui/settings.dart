import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';
import 'agent_options.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.studio});
  final Studio studio;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _base,
      _key,
      _imageBase,
      _imageKey,
      _videoBase,
      _videoKey,
      _imageModel,
      _agentModel,
      _proxy;
  late String _language, _theme;
  late ApiProtocol _protocol;
  late bool _vision, _motion, _imageStream, _imageResponseB64, _streamAgent;
  late int _limit;
  bool _checking = false, _saving = false;

  /// Null shows the list of module entries; 0..3 is the module opened from it.
  /// The settings are columns you step into, not tabs you flip between.
  ///
  /// Named `_module` and not `_section`: `_section` is already the widget helper
  /// below, and Dart members share a single namespace.
  int? _module;

  /// Which secret fields are currently shown in the clear. Keys are hidden by
  /// default, but on a phone there is no way to check what was typed without
  /// being able to reveal it.
  final _revealed = <TextEditingController, bool>{};
  var _agentEditor = GlobalKey<AgentOptionsEditorState>();
  late String _profileModel;
  late Map<String, AgentOptions> _profiles;
  late AgentOptions _options;
  String? _status;

  /// Diagnostic line shown under [_status]: the server's own words.
  String? _detail;

  /// Which check is in flight, so the spinner sits on the button that was tapped.
  String? _running;
  StudioApi? _client;
  final _cancel = CancelToken();
  Strings get s => Strings.of(context);

  @override
  void initState() {
    super.initState();
    final c = widget.studio.config;
    _base = TextEditingController(text: c.baseUrl);
    _key = TextEditingController(text: widget.studio.key);
    _imageBase = TextEditingController(text: c.imageBaseUrl);
    _imageKey = TextEditingController(text: widget.studio.imageKey);
    _videoBase = TextEditingController(text: c.videoBaseUrl);
    _videoKey = TextEditingController(text: widget.studio.videoKey);
    _imageModel = TextEditingController(text: c.imageModel);
    _agentModel = TextEditingController(text: c.agentModel);
    _proxy = TextEditingController(text: c.proxy);
    _language = widget.studio.languageSetting;
    _theme = widget.studio.theme;
    _protocol = c.protocol;
    _vision = c.vision;
    _limit = c.maxReferences;
    _motion = widget.studio.reduceMotion;
    _imageStream = c.imageStream;
    _imageResponseB64 = c.imageResponseB64;
    _streamAgent = c.streamAgent;
    _profiles = {...c.agentProfiles};
    _profileModel = c.agentModel;
    _options = c.agentOptions;
  }

  @override
  void dispose() {
    _cancel.cancel();
    _client?.close();
    for (final controller in [
      _base,
      _key,
      _imageBase,
      _imageKey,
      _videoBase,
      _videoKey,
      _imageModel,
      _agentModel,
      _proxy,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  ServiceConfig get config => ServiceConfig(
    baseUrl: _base.text.trim(),
    imageBaseUrl: _imageBase.text.trim(),
    videoBaseUrl: _videoBase.text.trim(),
    protocol: _protocol,
    imageModel: _imageModel.text.trim(),
    agentModel: _agentModel.text.trim(),
    vision: _vision,
    maxReferences: _limit,
    proxy: _proxy.text.trim(),
    imageStream: _imageStream,
    imageResponseB64: _imageResponseB64,
    streamAgent: _streamAgent,
    agentProfiles: _profiles,
  );

  /// Reports the outcome where the user is actually looking. The status line
  /// lives at the bottom of a long scrolling form, so on its own it reads as
  /// "the button did nothing".
  void _finish(String status, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _detail = detail;
    });
    final message = detail == null ? s.t(status) : '${s.t(status)}\n$detail';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  /// The check buttons carry the progress themselves. The status line and the
  /// linear indicator sit at the bottom of a long form, so a tap in the middle
  /// of it looks like nothing happened — long enough to matter, since a slow
  /// endpoint can take about a minute of timeouts before the first is reached.
  Widget _checkButton(
    String label,
    String what, {
    bool images = false,
    bool text = false,
  }) => OutlinedButton(
    onPressed: _checking ? null : () => _check(images: images, text: text),
    child: _running == what
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(s.t(label)),
  );

  void _selectAgentModel(String model) {
    final edited = _agentEditor.currentState?.read();
    if (_agentEditor.currentState != null && edited == null) return;
    final options = edited ?? _options;
    if (_profileModel.isNotEmpty) _profiles[_profileModel] = options;
    setState(() {
      _profileModel = model.trim();
      _agentModel.text = _profileModel;
      _options = _profiles[_profileModel] ?? const AgentOptions();
      _agentEditor = GlobalKey<AgentOptionsEditorState>();
    });
  }

  Future<void> _check({bool images = false, bool text = false}) async {
    if (text) {
      final options = _agentEditor.currentState?.read();
      if (_agentEditor.currentState != null && options == null) return;
      _profiles[_agentModel.text.trim()] = options ?? _options;
    }
    final what = text ? 'text' : (images ? 'images' : 'models');
    setState(() {
      _checking = true;
      _running = what;
      _status = null;
      _detail = null;
    });
    StudioApi? client;
    try {
      client = StudioApi(
        config,
        _key.text.trim(),
        _imageKey.text.trim(),
        widget.studio.store,
        videoKey: _videoKey.text.trim(),
      );
      _client = client;
      if (text) {
        final reply = await client.converse(
          [const ChatEntry('user', 'Reply with OK. Do not call any tools.')],
          [],
          _cancel,
        );
        if (reply.imagePrompt != null) {
          throw const FormatException('invalidResponse');
        }
        _finish('connected');
      } else {
        final models = await client.listModels(images: images);
        if (!mounted) return;
        if (models.isEmpty) {
          _finish('noModels');
          return;
        }
        final chosen = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(s.t(images ? 'imageModel' : 'agentModel')),
            children: [
              SizedBox(
                width: 400,
                height: 360,
                child: ListView.builder(
                  itemCount: models.length,
                  itemBuilder: (_, i) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, models[i]),
                    child: Text(models[i]),
                  ),
                ),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (chosen != null) {
          if (images) {
            _imageModel.text = chosen;
          } else {
            _selectAgentModel(chosen);
          }
        }
        _finish('connected', detail: '${models.length} models');
      }
    } catch (e) {
      _finish(
        errorCode(e),
        detail: errorDetailOf(e, secrets: [_key.text, _imageKey.text]),
      );
    } finally {
      client?.close();
      _client = null;
      if (mounted) {
        setState(() {
          _checking = false;
          _running = null;
        });
      }
    }
  }

  Future<void> _save() async {
    final value = _agentEditor.currentState?.read();
    if (_agentEditor.currentState != null && value == null) return;
    if (_agentModel.text.trim().isNotEmpty) {
      _profiles[_agentModel.text.trim()] = value ?? _options;
    }
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      await widget.studio.saveSettings(
        config,
        _key.text,
        _imageKey.text,
        _videoKey.text,
        _language,
        _theme,
        _motion,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _status = errorCode(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool secret = false,
    bool url = false,
    String? hint,
    ValueChanged<String>? onSubmitted,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: c,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      // A key stays hidden until it is asked for; an address is meant to be
      // read, and gets the keyboard that knows about dots and slashes.
      obscureText: secret && !(_revealed[c] ?? false),
      keyboardType: url ? TextInputType.url : null,
      autocorrect: false,
      enableSuggestions: false,
      textDirection: TextDirection.ltr,
      decoration: InputDecoration(
        labelText: s.t(label),
        hintText: hint,
        suffixIcon: !secret
            ? null
            : IconButton(
                tooltip: s.t((_revealed[c] ?? false) ? 'hideSecret' : 'showSecret'),
                icon: Icon(
                  (_revealed[c] ?? false)
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () =>
                    setState(() => _revealed[c] = !(_revealed[c] ?? false)),
              ),
      ),
    ),
  );

  /// The address a request will actually be sent to. The field above shows what
  /// was typed; this shows what it resolves to, which is where a doubled `/v1`
  /// or a missing path becomes visible — before the first failed request rather
  /// than after it.
  Widget _endpointPreview(TextEditingController c, {String path = ''}) {
    final host = c.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final suffix = path.isEmpty ? '' : '/$path';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        '${s.t('preview')}: ${host.isEmpty ? '—' : '$host$suffix'}',
        style: Theme.of(context).textTheme.bodySmall,
        textDirection: TextDirection.ltr,
      ),
    );
  }

  /// Fills the address — and, for the chat service, the protocol — from a known
  /// provider. A dropdown rather than a list of cards: the point is to save
  /// typing, not to become a directory of everything on the internet.
  Widget _builtinPicker(
    String service,
    TextEditingController host, {
    bool setsProtocol = false,
  }) {
    final providers = providersOf(service);
    if (providers.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey('provider:$service'),
        isExpanded: true,
        decoration: InputDecoration(labelText: s.t('builtinProvider')),
        hint: Text(s.t('customProvider')),
        items: [
          for (final provider in providers)
            DropdownMenuItem(
              value: provider.id,
              child: Text(
                provider.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (id) {
          BuiltinProvider? found;
          for (final provider in providers) {
            if (provider.id == id) found = provider;
          }
          final chosen = found;
          if (chosen == null) return;
          setState(() {
            host.text = chosen.host;
            if (setsProtocol) _protocol = chosen.protocol;
          });
        },
      ),
    );
  }

  /// The model library of one service. The selection still travels in the form
  /// and is written when the form is saved; the library is written on every
  /// change, because it outlives any single selection.
  Widget _modelSection(
    String service,
    TextEditingController selected, {
    ValueChanged<String>? onSelect,
  }) {
    final entries = widget.studio.modelsOf(service);
    final current = selected.text.trim();
    final missing = current.isNotEmpty && !entries.any((e) => e.id == current);

    // Selecting has to go through the caller for the agent service: its
    // parameter profile is keyed by model id, so writing the text alone would
    // leave the editor showing the previous model's options.
    void choose(String id) {
      if (onSelect != null) {
        onSelect(id);
      } else {
        selected.text = id;
      }
      setState(() {});
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.t('modelLibrary'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    _editModel(service, entries, choose: choose, current: current),
                icon: const Icon(Icons.add, size: 18),
                label: Text(s.t('addModel')),
              ),
            ],
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                s.t('noModelsYet'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final entry in entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                entry.id == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
              ),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: _capabilityLine(entry),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: s.t('editModel'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _editModel(
                      service,
                      entries,
                      choose: choose,
                      current: current,
                      entry: entry,
                    ),
                  ),
                  IconButton(
                    tooltip: s.t('deleteModel'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () =>
                        _deleteModel(service, entries, choose, current, entry),
                  ),
                ],
              ),
              onTap: () => choose(entry.id),
            ),
          // A value saved by an older build, or typed by hand, is not in the
          // library yet. Say so instead of showing nothing selected.
          if (missing)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${s.t('modelId')}: $current',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  /// What the row says about a model besides its name: the capability marks
  /// and the window, so the list answers "which one do I want" without opening
  /// each entry.
  Widget? _capabilityLine(ModelEntry entry) {
    final marks = <Widget>[
      if (entry.supports(ModelCapability.vision))
        Icon(Icons.visibility_outlined, size: 14, color: Theme.of(context).colorScheme.primary),
      if (entry.supports(ModelCapability.reasoning))
        Icon(Icons.lightbulb_outline, size: 14, color: Theme.of(context).colorScheme.tertiary),
      if (entry.supports(ModelCapability.toolUse))
        Icon(Icons.build_outlined, size: 14, color: Theme.of(context).colorScheme.secondary),
      if (entry.contextWindow > 0)
        Text(
          '${entry.contextWindow} tokens',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ];
    if (marks.isEmpty) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: marks);
  }

  Future<void> _editModel(
    String service,
    List<ModelEntry> entries, {
    required void Function(String id) choose,
    required String current,
    ModelEntry? entry,
  }) async {
    final result = await showDialog<ModelEntry>(
      context: context,
      builder: (_) => ModelEntryDialog(service: service, initial: entry),
    );
    if (result == null || !mounted) return;
    final id = result.id.trim();
    if (entries.any((other) => other.id == id && other.id != entry?.id)) {
      _finish('modelExists');
      return;
    }
    await widget.studio.saveModelLibrary(service, [
      for (final other in entries)
        if (other.id != entry?.id) other,
      result.copyWith(id: id),
    ]);
    if (!mounted) return;
    // A model added here becomes this service's model: adding it and then
    // hunting for it in the list would be two steps for one intent. Renaming
    // another model leaves the selection where it was.
    if (entry == null || entry.id == current) {
      choose(id);
    } else {
      setState(() {});
    }
  }

  Future<void> _deleteModel(
    String service,
    List<ModelEntry> entries,
    void Function(String id) choose,
    String current,
    ModelEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.t('deleteModel')),
        content: Text(s.t('deleteModelQuestion')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.studio.saveModelLibrary(service, [
      for (final other in entries)
        if (other.id != entry.id) other,
    ]);
    if (!mounted) return;
    // Deleting the selected model leaves the field empty rather than silently
    // pointing at whatever happened to be first in the list.
    if (entry.id == current) {
      choose('');
    } else {
      setState(() {});
    }
  }

  /// A row that opens [url]. No icon: the address is the label's other half.
  Widget _link(String label, String address, String url) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(s.t(label)),
    subtitle: Text(address),
    onTap: () => _open(url),
  );

  /// The version actually installed, read from the package rather than from the
  /// source tree, so it still answers correctly for a shipped build.
  Widget _version() => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(s.t('version')),
    subtitle: FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) =>
          Text(snapshot.hasData ? '${snapshot.data!.version}+${snapshot.data!.buildNumber}' : '…'),
    ),
  );

  Future<void> _open(String url) async {
    // A platform with no handler answers `false` rather than throwing, so the
    // return value is what decides whether the fallback is needed.
    bool opened;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    // Nothing here could take the link, so at least let it be copied.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: SelectableText(url)));
  }
  Widget _section(String label, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            s.t(label),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ...children,
      ],
    ),
  );

  /// The settings home: one row per module, in the order the app is used.
  Widget _entries() => Column(
    children: [
      for (final entry in const [
        (0, 'gallery'),
        (1, 'agent'),
        (4, 'videoConnection'),
        (2, 'generalSettings'),
        (3, 'about'),
      ])
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.t(entry.$2)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _openModule(entry.$1),
        ),
    ],
  );

  /// Opens a module, keeping the Agent editor's pending edit when it is valid.
  /// Enters a module. Named `_openModule` rather than `_open` because the class
  /// already has `_open(String url)` for the About links, and Dart members share
  /// a single namespace — a collision here is a compile error, not an overload.
  void _openModule(int section) {
    final options = _agentEditor.currentState?.read();
    if (_agentEditor.currentState != null && options == null) return;
    if (options != null) _options = options;
    setState(() => _module = section);
  }

  /// Leaves a module, keeping the Agent editor's pending edit when it is valid:
  /// the editor is disposed with the module, so what it holds has to be read out
  /// before it closes or the next visit shows stale values.
  void _close() {
    final options = _agentEditor.currentState?.read();
    if (_agentEditor.currentState != null && options == null) return;
    if (options != null) _options = options;
    setState(() => _module = null);
  }

  String get _title => switch (_module) {
    0 => s.t('gallery'),
    1 => s.t('agent'),
    2 => s.t('generalSettings'),
    3 => s.t('about'),
    4 => s.t('videoConnection'),
    _ => s.t('settings'),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_title),
      leading: _module == null ? null : BackButton(onPressed: _close),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            IgnorePointer(
              ignoring: _checking || _saving,
              child: Column(
                children: [
                  // Registers with the route so the system back button closes an
                  // open module instead of leaving Settings altogether.
                  PopScope(
                    canPop: _module == null,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) _close();
                    },
                    child: const SizedBox.shrink(),
                  ),
                  if (_module == null) _entries(),
                  if (_module == 0)
                    _section('imageConnection', [
                      _builtinPicker('image', _imageBase),
                      _field(
                        _imageBase,
                        'imageEndpoint',
                        url: true,
                        hint: 'https://…/v1',
                        onChanged: (_) => setState(() {}),
                      ),
                      _endpointPreview(_imageBase),
                      _field(_imageKey, 'imageKey', secret: true),
                      _modelSection('image', _imageModel),
                      DropdownButtonFormField<int>(
                        initialValue: _limit,
                        decoration: InputDecoration(labelText: s.t('limit')),
                        items: List.generate(
                          16,
                          (i) => DropdownMenuItem(
                            value: i + 1,
                            child: Text('${i + 1}'),
                          ),
                        ),
                        onChanged: (v) => setState(() => _limit = v!),
                      ),
                      const SizedBox(height: 12),
                      _checkButton('checkModels', 'images', images: true),
                      const SizedBox(height: 8),
                      Text(
                        s.t('checkNote'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(s.t('imageCompatibility')),
                        children: [
                          SwitchListTile(
                            title: Text(s.t('imageStream')),
                            subtitle: Text(s.t('imageStreamNote')),
                            value: _imageStream,
                            onChanged: (v) => setState(() => _imageStream = v),
                          ),
                          SwitchListTile(
                            title: Text(s.t('imageResponseB64')),
                            subtitle: Text(s.t('imageResponseB64Note')),
                            value: _imageResponseB64,
                            onChanged: (v) =>
                                setState(() => _imageResponseB64 = v),
                          ),
                        ],
                      ),
                    ]),
                  if (_module == 4)
                    _section('videoConnection', [
                      Text(
                        s.t('videoConnectionNote'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      _field(
                        _videoBase,
                        'videoEndpoint',
                        url: true,
                        hint: 'https://…/v1',
                      ),
                      _field(_videoKey, 'videoKey', secret: true),
                    ]),
                  if (_module == 1)
                    _section('connection', [
                      DropdownButtonFormField<ApiProtocol>(
                        isExpanded: true,
                        initialValue: _protocol,
                        decoration: InputDecoration(labelText: s.t('protocol')),
                        items: ApiProtocol.values
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(
                                  v.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _protocol = v!),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          'POST /${_protocol.chatPath}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _builtinPicker('agent', _base, setsProtocol: true),
                      _field(
                        _base,
                        'endpoint',
                        url: true,
                        hint: 'https://…/v1',
                        onChanged: (_) => setState(() {}),
                      ),
                      _endpointPreview(_base, path: _protocol.chatPath),
                      _field(_key, 'key', secret: true),
                      _modelSection(
                        'agent',
                        _agentModel,
                        onSelect: _selectAgentModel,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(s.t('modelDefaultsNote')),
                      ),
                      AgentOptionsEditor(
                        key: _agentEditor,
                        options: _options,
                        protocol: _protocol,
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.t('vision')),
                        value: _vision,
                        onChanged: (v) => setState(() => _vision = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.t('agentStream')),
                        subtitle: Text(s.t('agentStreamNote')),
                        value: _streamAgent,
                        onChanged: (v) => setState(() => _streamAgent = v),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          _checkButton('checkModels', 'models'),
                          _checkButton('checkText', 'text', text: true),
                        ],
                      ),
                    ]),
                  if (_module == 2)
                    _section('appearance', [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _language,
                        decoration: InputDecoration(labelText: s.t('language')),
                        items: [
                          DropdownMenuItem(
                            value: 'system',
                            child: Text(s.t('system')),
                          ),
                          ...Strings.names.entries.map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() => _language = v!),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _theme,
                        decoration: InputDecoration(labelText: s.t('theme')),
                        items: ['system', 'light', 'dark']
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(s.t(v)),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _theme = v!),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.t('reduceMotion')),
                        value: _motion,
                        onChanged: (v) => setState(() => _motion = v),
                      ),
                    ]),
                  if (_module == 2)
                    _section('network', [
                      _field(_proxy, 'proxy', hint: 'http://127.0.0.1:8080'),
                    ]),
                  if (_module == 2)
                    _section('storage', [Text(s.t('storageNote'))]),
                  if (_module == 2)
                    Text(
                      s.t('privacy'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_module == 3)
                    _section('about', [
                      _link(
                        'projectHome',
                        'github.com/Dai2010/imagyn',
                        'https://github.com/Dai2010/imagyn',
                      ),
                      _link(
                        'myGithub',
                        'github.com/Dai2010',
                        'https://github.com/Dai2010',
                      ),
                      _version(),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_checking) const LinearProgressIndicator(),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.t(_status!)),
                    if (_detail != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SelectableText(
                          _detail!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            if (_module != null && _module != 3)
              FilledButton(
                onPressed: _checking || _saving ? null : _save,
                child: Text(s.t('save')),
              ),
          ],
        ),
      ),
    ),
  );
}

/// One model, edited in place. The id is what travels in the request and the
/// alias is what the lists show, so the two are separate fields: renaming a
/// model for readability must not break the request.
class ModelEntryDialog extends StatefulWidget {
  const ModelEntryDialog({super.key, required this.service, this.initial});
  final String service;
  final ModelEntry? initial;
  @override
  State<ModelEntryDialog> createState() => _ModelEntryDialogState();
}

class _ModelEntryDialogState extends State<ModelEntryDialog> {
  late final _id = TextEditingController(text: widget.initial?.id ?? '');
  late final _alias = TextEditingController(text: widget.initial?.alias ?? '');
  late final _context = TextEditingController(
    text: switch (widget.initial?.contextWindow ?? 0) {
      0 => '',
      final value => '$value',
    },
  );
  late final _output = TextEditingController(
    text: switch (widget.initial?.maxOutput ?? 0) {
      0 => '',
      final value => '$value',
    },
  );
  late final Set<ModelCapability> _capabilities = {
    for (final capability
        in widget.initial?.capabilities ?? const <ModelCapability>[])
      capability,
  };

  /// Only a chat model has these: an image endpoint has no tool calling and no
  /// context window, so offering the switches there would be a lie.
  bool get _chat => widget.service == 'agent';

  /// The models this app already knows a starting point for. Picking one fills
  /// the id and, for a chat model, the window the provider documents.
  List<String> get _suggestions => switch (widget.service) {
    'agent' => [for (final preset in agentPresets) preset.model],
    'image' => [for (final preset in imagePresets) preset.model],
    _ => const [],
  };

  void _suggest(String model) {
    setState(() {
      _id.text = model;
      if (!_chat) return;
      for (final preset in agentPresets) {
        if (preset.model != model) continue;
        _context.text = '${preset.contextTokens}';
        final output = preset.maxOutputTokens;
        if (output != null) _output.text = '$output';
      }
    });
  }

  void _toggle(ModelCapability capability, bool on) => setState(() {
    if (on) {
      _capabilities.add(capability);
    } else {
      _capabilities.remove(capability);
    }
  });

  @override
  void dispose() {
    _id.dispose();
    _alias.dispose();
    _context.dispose();
    _output.dispose();
    super.dispose();
  }

  int _count(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final suggestions = _suggestions;
    return AlertDialog(
      title: Text(s.t('editModel')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (suggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final model in suggestions)
                        ActionChip(
                          label: Text(
                            model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () => _suggest(model),
                        ),
                    ],
                  ),
                ),
              TextField(
                controller: _id,
                autocorrect: false,
                enableSuggestions: false,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: s.t('modelId')),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _alias,
                decoration: InputDecoration(
                  labelText: s.t('alias'),
                  helperText: s.t('aliasNote'),
                  helperMaxLines: 2,
                ),
              ),
              if (_chat) ...[
                const SizedBox(height: 6),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _capabilities.contains(ModelCapability.vision),
                  title: Text(s.t('vision')),
                  onChanged: (on) =>
                      _toggle(ModelCapability.vision, on ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _capabilities.contains(ModelCapability.reasoning),
                  title: Text(s.t('reasoning')),
                  onChanged: (on) =>
                      _toggle(ModelCapability.reasoning, on ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _capabilities.contains(ModelCapability.toolUse),
                  title: Text(s.t('toolUse')),
                  subtitle: Text(s.t('toolUseNote')),
                  onChanged: (on) =>
                      _toggle(ModelCapability.toolUse, on ?? false),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _context,
                        keyboardType: TextInputType.number,
                        // Numbers without units are what makes a window read as
                        // ambiguous; the label carries the unit.
                        decoration: InputDecoration(
                          labelText: s.t('contextWindow'),
                          hintText: '128000',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _output,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: s.t('maxOutput'),
                          hintText: '4096',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('cancel')),
        ),
        FilledButton(
          onPressed: _id.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  ModelEntry(
                    id: _id.text.trim(),
                    alias: _alias.text.trim(),
                    capabilities: _chat ? _capabilities : const {},
                    contextWindow: _chat ? _count(_context) : 0,
                    maxOutput: _chat ? _count(_output) : 0,
                  ),
                ),
          child: Text(s.t('save')),
        ),
      ],
    );
  }
}
