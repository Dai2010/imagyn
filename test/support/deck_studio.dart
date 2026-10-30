import 'dart:typed_data';

import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';

import 'memory_store.dart';

/// A store the deck tests can write to: generated pictures really land in it,
/// and an id that names nothing still resolves to null.
class DeckStore extends MemoryStore {
  final savedAssets = <String, Asset>{};
  final savedJobs = <String, ImageJob>{};

  @override
  Future<List<Asset>> assets() async => savedAssets.values.toList();

  @override
  Future<Asset?> asset(String id) async => savedAssets[id];

  @override
  Future<List<ImageJob>> jobs() async => savedJobs.values.toList();

  @override
  Future<void> deleteJob(String id) async {
    savedJobs.remove(id);
  }

  @override
  Future<void> job(String id, String state, Map<String, dynamic> record) async {
    savedJobs[id] = ImageJob(id, state, record);
  }

  @override
  Future<Asset> saveAsset(
    Uint8List bytes, {
    String prompt = '',
    String? parentId,
    Map<String, dynamic> parameters = const {},
  }) async {
    final id = newId();
    final asset = Asset(
      id: id,
      path: 'assets/$id.png',
      mime: 'image/png',
      prompt: prompt,
      createdAt: DateTime.utc(2026),
      parentId: parentId,
      parameters: parameters,
    );
    savedAssets[id] = asset;
    return asset;
  }
}

class DeckStudio extends Studio {
  DeckStudio([MemoryStore? store]) : super(store ?? DeckStore()) {
    onboarding = false;
    languageSetting = 'zh';
    config = const ServiceConfig(agentModel: 'agent', imageModel: 'image');
  }
}
