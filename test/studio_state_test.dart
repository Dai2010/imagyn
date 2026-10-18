import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';

import 'support/memory_store.dart';

class StateStore extends MemoryStore {
  final savedAssets = <String, Asset>{};
  final savedJobs = <String, ImageJob>{};
  Future<void> Function()? beforeFavoriteWrite;

  @override
  Future<List<Asset>> assets() async => savedAssets.values.toList();

  @override
  Future<Asset?> asset(String id) async => savedAssets[id];

  @override
  Future<void> deleteAsset(String id) async {
    savedAssets.remove(id);
  }

  @override
  Future<void> deleteJob(String id) async {
    savedJobs.remove(id);
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

  @override
  Future<void> job(String id, String state, Map<String, dynamic> record) async {
    savedJobs[id] = ImageJob(id, state, record);
  }

  @override
  Future<List<ImageJob>> jobs() async =>
      savedJobs.values.where((job) => job.state != 'complete').toList();

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == 'favorites') await beforeFavoriteWrite?.call();
    await super.setSetting(key, value);
  }
}

Asset image(String id) => Asset(
  id: id,
  path: 'assets/$id.png',
  mime: 'image/png',
  prompt: 'image $id',
  createdAt: DateTime.utc(2026),
);

void main() {
  test(
    'startup restores the same latest image as switching conversations',
    () async {
      final store = StateStore()
        ..savedConfig = const ServiceConfig(vision: true);
      final older = image('older');
      final latest = image('latest');
      store.savedAssets.addAll({older.id: older, latest.id: latest});
      store.settings['currentSession'] = 'existing';
      store.records['existing'] = [
        ChatEntry('assistant', '', assetIds: [older.id]),
        const ChatEntry('user', 'make it red'),
        ChatEntry('assistant', '', assetIds: [latest.id]),
        const ChatEntry('user', 'thanks'),
        const ChatEntry('assistant', 'you are welcome'),
      ];
      final studio = Studio(store);
      addTearDown(studio.dispose);

      await studio.initialize();
      expect(studio.session, 'existing');
      expect(studio.agentRefs.map((asset) => asset.id), [latest.id]);

      await studio.newConversation();
      expect(studio.agentRefs, isEmpty);
      await studio.switchConversation('existing');
      expect(studio.agentRefs.map((asset) => asset.id), [latest.id]);
    },
  );

  test(
    'text-only conversations do not restore automatic image references',
    () async {
      final store = StateStore();
      final asset = image('latest');
      store.savedAssets[asset.id] = asset;
      store.settings['currentSession'] = 'existing';
      store.records['existing'] = [
        ChatEntry('assistant', '', assetIds: [asset.id]),
      ];
      final studio = Studio(store);
      addTearDown(studio.dispose);

      await studio.initialize();
      expect(studio.agentRefs, isEmpty);
      await studio.newConversation();
      await studio.switchConversation('existing');
      expect(studio.agentRefs, isEmpty);
    },
  );

  test('manual references still require a vision-capable Agent', () async {
    final store = StateStore()
      ..savedConfig = const ServiceConfig(
        baseUrl: 'https://example.invalid/v1',
        agentModel: 'agent',
      );
    final studio = Studio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    studio.useReference(image('manual'), true);

    await expectLater(
      studio.submit('describe this image', true, const ImageOptions()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'visionDisabled',
        ),
      ),
    );
    expect(studio.chat, isEmpty);
  });

  test(
    'text-only Agent can chat again after a successful image generation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      var agentRequests = 0;
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/images/generations')) {
          request.response.write(
            jsonEncode({
              'data': [
                {'b64_json': base64Encode(png)},
              ],
            }),
          );
        } else {
          agentRequests++;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': agentRequests == 1
                      ? {
                          'content': '',
                          'tool_calls': [
                            {
                              'type': 'function',
                              'function': {
                                'name': 'generate_image',
                                'arguments': jsonEncode({
                                  'prompt': 'a red fox',
                                }),
                              },
                            },
                          ],
                        }
                      : {'content': 'you are welcome'},
                },
              ],
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final store = StateStore()
        ..savedConfig = ServiceConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          agentModel: 'agent',
          imageModel: 'image',
        );
      final studio = Studio(store);
      addTearDown(studio.dispose);
      await studio.initialize();

      await studio.submit('draw a fox', true, const ImageOptions());
      expect(studio.error, isNull);
      expect(studio.gallery, hasLength(1));
      expect(studio.agentRefs, isEmpty);
      await studio.submit('thanks', true, const ImageOptions());
      expect(studio.error, isNull);
      // One request for the call, one continuation after its result, and one
      // for the follow-up turn.
      expect(agentRequests, 3);
      expect(studio.chat.last.text, 'you are welcome');
    },
  );

  for (final vision in [true, false]) {
    test('download retry preserves edit parent with vision=$vision', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        expect(request.uri.path, '/result.png');
        request.response.add(png);
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final store = StateStore()..savedConfig = ServiceConfig(vision: vision);
      final studio = Studio(store);
      addTearDown(studio.dispose);
      await studio.initialize();
      final job = ImageJob('job', 'failed', {
        'prompt': 'make the original red',
        'references': ['original'],
        'outputs': ['http://127.0.0.1:${server.port}/result.png'],
        'session': studio.session,
      });

      await studio.retryDownload(job);
      expect(studio.error, isNull);
      expect(requests, 1);
      expect(studio.gallery.single.parentId, 'original');
      expect(studio.gallery.single.parameters.containsKey('outputs'), isFalse);
      expect(store.savedJobs[job.id]!.state, 'complete');
      expect(store.savedJobs[job.id]!.record.containsKey('outputs'), isFalse);
      expect(studio.chat.single.assetIds, [studio.gallery.single.id]);
      expect(
        studio.agentRefs.map((asset) => asset.id),
        vision ? [studio.gallery.single.id] : isEmpty,
      );
    });
  }

  test(
    'concurrent favorites preserve both images in memory and storage',
    () async {
      final store = StateStore();
      final studio = Studio(store);
      addTearDown(studio.dispose);
      await studio.initialize();
      final firstWrite = Completer<void>();
      final firstWriteStarted = Completer<void>();
      var writes = 0;
      store.beforeFavoriteWrite = () async {
        if (writes++ == 0) {
          firstWriteStarted.complete();
          await firstWrite.future;
        }
      };

      final first = studio.toggleFavorite(image('a'));
      final second = studio.toggleFavorite(image('b'));
      await firstWriteStarted.future;
      firstWrite.complete();
      await Future.wait([first, second]);

      expect(studio.favorites, {'a', 'b'});
      expect(
        jsonDecode(store.settings['favorites']!),
        unorderedEquals(['a', 'b']),
      );
    },
  );

  test('two overlapping toggles of one image cancel each other', () async {
    final store = StateStore();
    final studio = Studio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    final firstWrite = Completer<void>();
    final firstWriteStarted = Completer<void>();
    var writes = 0;
    store.beforeFavoriteWrite = () async {
      if (writes++ == 0) {
        firstWriteStarted.complete();
        await firstWrite.future;
      }
    };
    final asset = image('a');

    final first = studio.toggleFavorite(asset);
    final second = studio.toggleFavorite(asset);
    await firstWriteStarted.future;
    firstWrite.complete();
    await Future.wait([first, second]);

    expect(studio.favorites, isEmpty);
    expect(jsonDecode(store.settings['favorites']!), isEmpty);
  });

  test('a failed favorite write leaves later toggles usable', () async {
    final store = StateStore();
    final studio = Studio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    var writes = 0;
    store.beforeFavoriteWrite = () async {
      if (writes++ == 0) throw StateError('write failed');
    };

    final first = studio.toggleFavorite(image('a'));
    final failure = expectLater(first, throwsStateError);
    final second = studio.toggleFavorite(image('b'));
    await failure;
    await second;

    expect(studio.favorites, {'b'});
    expect(jsonDecode(store.settings['favorites']!), ['b']);
  });

  test('deleting an image removes it from the gallery and favorites', () async {
    final store = StateStore();
    final gone = image('gone');
    final kept = image('kept');
    store.savedAssets.addAll({gone.id: gone, kept.id: kept});
    store.settings['favorites'] = jsonEncode([gone.id, kept.id]);
    final studio = Studio(store);
    addTearDown(studio.dispose);
    await studio.initialize();

    expect(
      studio.gallery.map((asset) => asset.id),
      containsAll([gone.id, kept.id]),
    );
    await studio.deleteAsset(gone);

    expect(studio.gallery.map((asset) => asset.id), [kept.id]);
    expect(studio.favorites, {kept.id});
    expect(store.savedAssets.containsKey(gone.id), isFalse);
  });

  test('a submitting record can be deleted', () async {
    final store = StateStore();
    final studio = Studio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    final job = ImageJob('job', 'submitting', {'prompt': 'a fox'});
    store.savedJobs[job.id] = job;
    studio.jobs = [job];

    await studio.deleteJob(job);

    expect(store.savedJobs, isEmpty);
    expect(studio.jobs, isEmpty);
  });

  test('a deleted record is not restored by a late download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
    );
    final requested = Completer<void>();
    final release = Completer<void>();
    final subscription = server.listen((request) async {
      if (!requested.isCompleted) requested.complete();
      await release.future;
      request.response.add(png);
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    final store = StateStore();
    final studio = Studio(store);
    addTearDown(studio.dispose);
    await studio.initialize();
    final job = ImageJob('job', 'failed', {
      'prompt': 'a fox',
      'outputs': ['http://127.0.0.1:${server.port}/result.png'],
      'session': studio.session,
    });
    store.savedJobs[job.id] = job;
    studio.jobs = [job];

    final retry = studio.retryDownload(job);
    await requested.future;
    await studio.deleteJob(job);
    release.complete();
    await retry;

    expect(store.savedJobs, isEmpty);
    expect(studio.jobs, isEmpty);
  });
}
