import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/studio.dart';
import '../l10n/strings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.studio});
  final Studio studio;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _base, _key, _imageBase, _imageKey, _imageModel, _agentModel, _proxy;
  late String _language, _theme;
  late ApiProtocol _protocol;
  late bool _vision, _motion;
  late int _limit;
  bool _checking = false, _saving = false;
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
    _language = widget.studio.languageSetting; _theme = widget.studio.theme;
    _protocol = c.protocol; _vision = c.vision; _limit = c.maxReferences;
    _motion = widget.studio.reduceMotion;
  }
  @override
  void dispose() {
    _cancel.cancel(); _client?.close();
    for (final controller in [_base, _key, _imageBase, _imageKey, _imageModel, _agentModel, _proxy]) { controller.dispose(); }
    super.dispose();
  }

  ServiceConfig get config => ServiceConfig(baseUrl: _base.text.trim(), imageBaseUrl: _imageBase.text.trim(),
    protocol: _protocol, imageModel: _imageModel.text.trim(), agentModel: _agentModel.text.trim(),
    vision: _vision, maxReferences: _limit, proxy: _proxy.text.trim());

  /// Reports the outcome where the user is actually looking. The status line
  /// lives at the bottom of a long scrolling form, so on its own it reads as
  /// "the button did nothing".
  void _finish(String status, {String? detail}) {
    if (!mounted) return;
    setState(() { _status = status; _detail = detail; });
    final message = detail == null ? s.t(status) : '${s.t(status)}\n$detail';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)));
  }

  /// The check buttons carry the progress themselves. The status line and the
  /// linear indicator sit at the bottom of a long form, so a tap in the middle
  /// of it looks like nothing happened — long enough to matter, since a slow
  /// endpoint can take about a minute of timeouts before the first is reached.
  Widget _checkButton(String label, String what, {bool images = false, bool text = false}) =>
    OutlinedButton(
      onPressed: _checking ? null : () => _check(images: images, text: text),
      child: _running == what
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(s.t(label)));

  Future<void> _check({bool images = false, bool text = false}) async {
    final what = text ? 'text' : (images ? 'images' : 'models');
    setState(() { _checking = true; _running = what; _status = null; _detail = null; });
    StudioApi? client;
    try {
      client = StudioApi(config, _key.text.trim(), _imageKey.text.trim(), widget.studio.store);
      _client = client;
      if (text) {
        final reply = await client.converse([const ChatEntry('user', 'Reply with OK. Do not call any tools.')], [], _cancel);
        if (reply.imagePrompt != null) throw const FormatException('invalidResponse');
        _finish('connected');
      } else {
        final models = await client.listModels(images: images);
        if (!mounted) return;
        if (models.isEmpty) { _finish('noModels'); return; }
        final chosen = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
          title: Text(s.t(images ? 'imageModel' : 'agentModel')), children: [
            SizedBox(width: 400, height: 360, child: ListView.builder(itemCount: models.length,
              itemBuilder: (_, i) => SimpleDialogOption(onPressed: () => Navigator.pop(context, models[i]), child: Text(models[i])))),
          ]));
        if (!mounted) return;
        if (chosen != null) (images ? _imageModel : _agentModel).text = chosen;
        _finish('connected', detail: '${models.length} models');
      }
    } catch (e) {
      _finish(errorCode(e), detail: errorDetailOf(e, secrets: [_key.text, _imageKey.text]));
    }
    finally { client?.close(); _client = null; if (mounted) setState(() { _checking = false; _running = null; }); }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _status = null; });
    try {
      await widget.studio.saveSettings(config, _key.text, _imageKey.text, _language, _theme, _motion);
      if (mounted) Navigator.pop(context);
    } catch (e) { if (mounted) setState(() => _status = errorCode(e)); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  Widget _field(TextEditingController c, String label, {bool secret = false, String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 14), child: TextField(controller: c, obscureText: secret,
      autocorrect: false, enableSuggestions: false, textDirection: TextDirection.ltr,
      decoration: InputDecoration(labelText: s.t(label), hintText: hint)));
  Widget _section(String label, List<Widget> children) => Padding(padding: const EdgeInsets.only(bottom: 28),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(bottom: 14), child: Text(s.t(label), style: Theme.of(context).textTheme.titleMedium)),
      ...children,
    ]));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(s.t('settings'))),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680),
      child: ListView(padding: const EdgeInsets.all(24), children: [
        IgnorePointer(ignoring: _checking || _saving, child: Column(children: [
          _section('appearance', [
            DropdownButtonFormField<String>(initialValue: _language, decoration: InputDecoration(labelText: s.t('language')),
              items: [
                DropdownMenuItem(value: 'system', child: Text(s.t('system'))),
                ...Strings.names.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
              ],
              onChanged: (v) => setState(() => _language = v!)),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(initialValue: _theme, decoration: InputDecoration(labelText: s.t('theme')),
              items: ['system','light','dark'].map((v) => DropdownMenuItem(value: v, child: Text(s.t(v)))).toList(),
              onChanged: (v) => setState(() => _theme = v!)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(s.t('reduceMotion')), value: _motion,
              onChanged: (v) => setState(() => _motion = v)),
          ]),
          _section('connection', [
            DropdownButtonFormField<ApiProtocol>(initialValue: _protocol,
              decoration: InputDecoration(labelText: s.t('protocol')),
              items: ApiProtocol.values.map((v) => DropdownMenuItem(value: v,
                child: Text(v == ApiProtocol.openai ? 'OpenAI' : 'Anthropic / Claude'))).toList(),
              onChanged: (v) => setState(() => _protocol = v!)),
            const SizedBox(height: 14),
            _field(_base, 'endpoint', hint: 'https://…/v1'), _field(_key, 'key', secret: true),
            _field(_agentModel, 'agentModel'),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(s.t('vision')), value: _vision,
              onChanged: (v) => setState(() => _vision = v)),
            Wrap(spacing: 8, children: [
              _checkButton('checkModels', 'models'),
              _checkButton('checkText', 'text', text: true),
            ]),
          ]),
          _section('imageConnection', [
            _field(_imageBase, 'imageEndpoint', hint: 'https://…/v1'),
            _field(_imageKey, 'imageKey', secret: true), _field(_imageModel, 'imageModel'),
            DropdownButtonFormField<int>(initialValue: _limit, decoration: InputDecoration(labelText: s.t('limit')),
              items: List.generate(16, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
              onChanged: (v) => setState(() => _limit = v!)),
            const SizedBox(height: 12),
            _checkButton('checkModels', 'images', images: true),
            const SizedBox(height: 8), Text(s.t('checkNote'), style: Theme.of(context).textTheme.bodySmall),
          ]),
          _section('network', [_field(_proxy, 'proxy', hint: 'http://127.0.0.1:8080')]),
          _section('storage', [Text(s.t('storageNote'))]),
          Text(s.t('privacy'), style: Theme.of(context).textTheme.bodySmall),
        ])),
        const SizedBox(height: 20),
        if (_checking) const LinearProgressIndicator(),
        if (_status != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.t(_status!)),
            if (_detail != null) Padding(padding: const EdgeInsets.only(top: 6),
              child: SelectableText(_detail!, style: Theme.of(context).textTheme.bodySmall)),
          ])),
        FilledButton(onPressed: _checking || _saving ? null : _save, child: Text(s.t('save'))),
      ]))),
  );
}
