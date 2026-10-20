import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/models.dart';
import 'package:imagyn/core/studio.dart';
import 'package:path/path.dart' as p;

import 'support/deck_studio.dart';

/// MemoryStore implements LocalStore through noSuchMethod, so a test that
/// really writes a file needs the two members the share path uses.
class _ShareStore extends DeckStore {
  _ShareStore(this.root);
  @override
  final Directory root;
  @override
  File file(Asset asset) => File(p.join(root.path, asset.path));
}

void main() {
  late Directory root;
  late _ShareStore store;
  late Studio studio;
  late List<({String path, String? subject})> shared;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('imagyn-share-test');
    store = _ShareStore(root);
    shared = [];
    studio = Studio(
      store,
      shareFile: (path, subject) async {
        shared.add((path: path, subject: subject));
      },
    );
    await studio.initialize();
  });

  tearDown(() async {
    studio.dispose();
    await root.delete(recursive: true);
  });

  test('sharing a picture hands its stored path and prompt over', () async {
    final asset = await store.saveAsset(
      Uint8List.fromList([1, 2, 3]),
      prompt: '  一只狐狸  ',
    );

    await studio.shareAsset(asset);

    expect(shared, hasLength(1));
    expect(shared.single.path, store.file(asset).path);
    expect(shared.single.subject, '一只狐狸');
  });

  test('a picture without a prompt is shared without a subject', () async {
    final asset = await store.saveAsset(Uint8List.fromList([1]));

    await studio.shareAsset(asset);

    expect(shared.single.subject, isNull);
  });

  test('sharing a deck writes the pptx before handing it over', () async {
    final deck = Deck(
      id: 'd1',
      title: '分享演示',
      backgroundImageId: null,
      slides: [
        const Slide(title: '第一页', bullets: ['要点']),
      ],
    );

    await studio.shareDeck(deck);

    expect(shared, hasLength(1));
    expect(shared.single.subject, '分享演示');
    expect(shared.single.path, endsWith('分享演示.pptx'));
    final file = File(shared.single.path);
    expect(await file.exists(), isTrue);
    expect(await file.length(), greaterThan(0));
    // The same bytes the export writes, so the sheet can open them in any
    // presentation app.
    final head = await file.openRead(0, 2).first;
    expect(String.fromCharCodes(head), 'PK');
  });
}
