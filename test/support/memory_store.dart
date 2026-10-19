import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/store.dart';

class MemoryStore implements LocalStore {
  final settings = <String, String>{'onboardingVersion': '1', 'language': 'zh'};
  final records = <String, List<ChatEntry>>{};
  final savedDecks = <String, Map<String, Deck>>{};
  ServiceConfig savedConfig = const ServiceConfig(
    agentModel: 'agent-a',
    imageModel: 'image-a',
  );
  int sequence = 0;
  @override
  Future<String?> setting(String key) async => settings[key];
  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<ServiceConfig> config() async => savedConfig;
  @override
  Future<String> apiKey() async => 'test-key';
  @override
  Future<String> imageKey() async => '';
  @override
  String newId() => 'session-${sequence++}';
  @override
  Future<int> recoverJobs() async => 0;
  @override
  Future<List<Asset>> assets() async => [];
  @override
  Future<List<ImageJob>> jobs() async => [];
  @override
  Future<List<ChatEntry>> messages(String session) async =>
      List.of(records[session] ?? []);
  @override
  Future<void> addMessage(String session, ChatEntry entry) async {
    (records[session] ??= []).add(entry);
  }

  @override
  Future<void> saveDeck(Deck deck, String session) async {
    (savedDecks[session] ??= {})[deck.id] = Deck.fromJson(deck.toJson());
  }

  @override
  Future<List<Deck>> decks(String session) async =>
      List.of(savedDecks[session]?.values ?? const <Deck>[]);

  @override
  Future<void> deleteDeck(String id) async {
    for (final session in savedDecks.values) {
      session.remove(id);
    }
  }

  @override
  Future<void> saveConfig(
    ServiceConfig config,
    String key,
    String imageKey,
  ) async {
    savedConfig = config;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
