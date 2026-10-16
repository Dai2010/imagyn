import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api.dart';
import '../core/models.dart';
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
      _imageModel,
      _agentModel,
      _proxy;
  late String _language, _theme;
  late ApiProtocol _protocol;
  late bool _vision, _motion, _imageStream, _imageResponseB64, _streamAgent;
  late int _limit;
  bool _checking = false, _saving = false;
  int _tab = 0;

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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: c,
      onSubmitted: onSubmitted,
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

  /// A tab label, pinned to a single line on purpose: a wrapped label makes the
  /// button taller, and the room the AppBar gives this row is fixed — the growth
  /// then shows up as a vertical overflow instead of a cramped label.
  Widget _tabLabel(String key) =>
      Text(s.t(key), maxLines: 1, overflow: TextOverflow.ellipsis);

  Widget _tabs() => SegmentedButton<int>(
    segments: [
      ButtonSegment(value: 0, label: _tabLabel('gallery')),
      ButtonSegment(value: 1, label: _tabLabel('agent')),
      ButtonSegment(value: 2, label: _tabLabel('generalSettings')),
      ButtonSegment(value: 3, label: _tabLabel('about')),
    ],
    selected: {_tab},
    onSelectionChanged: (selection) {
      final options = _agentEditor.currentState?.read();
      if (_agentEditor.currentState != null && options == null) {
        return;
      }
      if (options != null) _options = options;
      setState(() => _tab = selection.single);
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(s.t('settings')),
      bottom: PreferredSize(
        // The button plus the gap under it (60 + 12), with slack for a larger
        // text scale: the AppBar lays this row out at a fixed height, so a
        // short slot would overflow rather than simply look tight.
        preferredSize: const Size.fromHeight(72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: IgnorePointer(ignoring: _checking || _saving, child: _tabs()),
        ),
      ),
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
                  if (_tab == 0)
                    _section('imageConnection', [
                      _field(
                        _imageBase,
                        'imageEndpoint',
                        url: true,
                        hint: 'https://…/v1',
                      ),
                      _field(_imageKey, 'imageKey', secret: true),
                      _field(_imageModel, 'imageModel'),
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
                  if (_tab == 1)
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
                      _field(_base, 'endpoint', url: true, hint: 'https://…/v1'),
                      _field(_key, 'key', secret: true),
                      _field(
                        _agentModel,
                        'agentModel',
                        onSubmitted: _selectAgentModel,
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
                  if (_tab == 2)
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
                  if (_tab == 2)
                    _section('network', [
                      _field(_proxy, 'proxy', hint: 'http://127.0.0.1:8080'),
                    ]),
                  if (_tab == 2)
                    _section('storage', [Text(s.t('storageNote'))]),
                  if (_tab == 2)
                    Text(
                      s.t('privacy'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_tab == 3)
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
            if (_tab != 3)
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
