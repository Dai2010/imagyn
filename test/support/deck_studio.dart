import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';

import 'memory_store.dart';

/// A store whose assets never resolve, so a slide that names an image still
/// renders its placeholder instead of reaching for the disk.
class DeckStore extends MemoryStore {
  @override
  Future<Asset?> asset(String id) async => null;
}

class DeckStudio extends Studio {
  DeckStudio([MemoryStore? store]) : super(store ?? DeckStore()) {
    onboarding = false;
    languageSetting = 'zh';
    config = const ServiceConfig(agentModel: 'agent', imageModel: 'image');
  }
}
