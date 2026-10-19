import 'package:flutter/material.dart';

import '../core/models.dart';
import '../l10n/strings.dart';

class AgentOptionsEditor extends StatefulWidget {
  const AgentOptionsEditor({
    super.key,
    required this.options,
    required this.protocol,
  });
  final AgentOptions options;
  final ApiProtocol protocol;

  @override
  State<AgentOptionsEditor> createState() => AgentOptionsEditorState();
}

class AgentOptionsEditorState extends State<AgentOptionsEditor> {
  final _form = GlobalKey<FormState>();
  late final _prompt = TextEditingController(text: widget.options.systemPrompt);
  late final _context = TextEditingController(
    text: '${widget.options.contextMessages}',
  );
  late final _contextTokens = TextEditingController(
    text: '${widget.options.contextTokens}',
  );
  late final _tokens = TextEditingController(
    text: widget.options.maxOutputTokens?.toString() ?? '',
  );
  late final _temperature = TextEditingController(
    text: widget.options.temperature?.toString() ?? '',
  );
  late final _topP = TextEditingController(
    text: widget.options.topP?.toString() ?? '',
  );

  AgentOptions? read() {
    if (!_form.currentState!.validate()) return null;
    final value = AgentOptions(
      systemPrompt: _prompt.text,
      contextMessages: int.parse(_context.text.trim()),
      contextTokens: int.parse(_contextTokens.text.trim()),
      maxOutputTokens: int.tryParse(_tokens.text.trim()),
      temperature: double.tryParse(_temperature.text.trim()),
      topP: double.tryParse(_topP.text.trim()),
    );
    try {
      value.validate(widget.protocol);
      return value;
    } on FormatException {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).t('invalidAgentOptions'))),
      );
      return null;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _prompt,
      _context,
      _contextTokens,
      _tokens,
      _temperature,
      _topP,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _number(
    TextEditingController controller,
    String label,
    double min,
    double max, {
    bool integer = false,
    bool optional = true,
  }) {
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        key: ValueKey(label),
        keyboardType: TextInputType.numberWithOptions(decimal: !integer),
        decoration: InputDecoration(
          labelText: s.t(label),
          hintText: optional ? s.t('serviceDefault') : null,
        ),
        validator: (text) {
          final input = text!.trim();
          if (optional && input.isEmpty) return null;
          final value = integer ? int.tryParse(input) : double.tryParse(input);
          return value == null || !value.isFinite || value < min || value > max
              ? s.t('invalidAgentOptions')
              : null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: const ValueKey('systemPrompt'),
            controller: _prompt,
            minLines: 4,
            maxLines: 10,
            maxLength: 128000,
            decoration: InputDecoration(
              labelText: s.t('systemPrompt'),
              helperText: s.t('systemPromptNote'),
              helperMaxLines: 3,
              counterText: '',
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: () => _prompt.text = defaultAgentPrompt,
              child: Text(s.t('restorePrompt')),
            ),
          ),
          _number(
            _context,
            'contextMessages',
            0,
            10000,
            integer: true,
            optional: false,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              s.t('contextNote'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          _number(
            _contextTokens,
            'contextTokens',
            0,
            10000000,
            integer: true,
            optional: false,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              s.t('compactionNote'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          _number(
            _tokens,
            'maxOutputTokens',
            widget.protocol == ApiProtocol.responses ? 16 : 1,
            1048576,
            integer: true,
          ),
          _number(
            _temperature,
            'temperature',
            0,
            widget.protocol == ApiProtocol.anthropic ? 1 : 2,
          ),
          _number(_topP, 'topP', 0, 1),
          Text(
            s.t('samplingNote'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

Future<AgentOptions?> showAgentOptions(
  BuildContext context,
  AgentOptions options,
  ApiProtocol protocol,
) {
  final editor = GlobalKey<AgentOptionsEditorState>();
  final s = Strings.of(context);
  return showModalBottomSheet<AgentOptions>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: ListView(
          padding: const EdgeInsets.all(20),
          shrinkWrap: true,
          children: [
            Text(
              s.t('conversationSettings'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(s.t('sessionOnly')),
            ),
            AgentOptionsEditor(
              key: editor,
              options: options,
              protocol: protocol,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final value = editor.currentState!.read();
                if (value != null) Navigator.pop(context, value);
              },
              child: Text(s.t('save')),
            ),
          ],
        ),
      ),
    ),
  );
}
