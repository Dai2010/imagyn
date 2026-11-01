import 'models.dart';

/// A starting point for a connection: the address, the protocol it speaks, and
/// the model ids the provider publishes.
///
/// A preset only saves typing. Nothing is locked — the address stays editable,
/// the protocol can be switched, and the models it lists are ordinary entries
/// the user can rename or delete. That is also why the list stays short: an
/// address that nobody verified is worse than an empty field, because it fails
/// later, at request time, instead of at the moment it is typed.
class BuiltinProvider {
  const BuiltinProvider({
    required this.id,
    required this.name,
    required this.host,
    this.protocol = ApiProtocol.openai,
    this.models = const [],
  });

  final String id;
  final String name;
  final String host;
  final ApiProtocol protocol;
  final List<String> models;
}

/// Providers that serve chat completions. Anything that speaks the OpenAI or
/// Anthropic shape fits; the protocol field is what decides how it is called.
const chatProviders = <BuiltinProvider>[
  BuiltinProvider(id: 'openai', name: 'OpenAI', host: 'https://api.openai.com/v1'),
  BuiltinProvider(
    id: 'anthropic',
    name: 'Anthropic',
    host: 'https://api.anthropic.com/v1',
    protocol: ApiProtocol.anthropic,
  ),
  BuiltinProvider(
    id: 'deepseek',
    name: 'DeepSeek',
    host: 'https://api.deepseek.com/v1',
    models: ['deepseek-chat', 'deepseek-reasoner'],
  ),
  BuiltinProvider(
    id: 'siliconflow',
    name: 'SiliconFlow',
    host: 'https://api.siliconflow.cn/v1',
  ),
  BuiltinProvider(
    id: 'moonshot',
    name: 'Moonshot',
    host: 'https://api.moonshot.cn/v1',
  ),
  BuiltinProvider(
    id: 'zhipu',
    name: 'Zhipu GLM',
    host: 'https://open.bigmodel.cn/api/paas/v4',
  ),
  BuiltinProvider(
    id: 'dashscope',
    name: 'DashScope',
    host: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
  BuiltinProvider(
    id: 'ark',
    name: 'Volcengine Ark',
    host: 'https://ark.cn-beijing.volces.com/api/v3',
  ),
  BuiltinProvider(
    id: 'openrouter',
    name: 'OpenRouter',
    host: 'https://openrouter.ai/api/v1',
  ),
];

/// Providers that render stills. The address is what matters here; the image
/// model ids change too often to guess, so they are not pre-filled.
const imageProviders = <BuiltinProvider>[
  BuiltinProvider(id: 'openai', name: 'OpenAI', host: 'https://api.openai.com/v1'),
  BuiltinProvider(
    id: 'siliconflow',
    name: 'SiliconFlow',
    host: 'https://api.siliconflow.cn/v1',
  ),
  BuiltinProvider(
    id: 'dashscope',
    name: 'DashScope',
    host: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
  BuiltinProvider(
    id: 'zhipu',
    name: 'Zhipu GLM',
    host: 'https://open.bigmodel.cn/api/paas/v4',
  ),
];

/// Providers that render clips. Same rule as the image list: address only.
const videoProviders = <BuiltinProvider>[
  BuiltinProvider(
    id: 'ark',
    name: 'Volcengine Ark',
    host: 'https://ark.cn-beijing.volces.com/api/v3',
  ),
  BuiltinProvider(
    id: 'dashscope',
    name: 'DashScope',
    host: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
];

/// The preset list for one service, so the settings page picks by name rather
/// than by which of three identical dropdowns it is building.
List<BuiltinProvider> providersOf(String service) => switch (service) {
  'agent' => chatProviders,
  'image' => imageProviders,
  'video' => videoProviders,
  _ => const [],
};
