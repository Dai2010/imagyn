import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../l10n/strings.dart';
import 'api.dart';
import 'background.dart';
import 'import.dart';
import 'models.dart';
import 'pptx.dart';
import 'pptx_import.dart';
import 'share.dart';
import 'store.dart';
import 'styles.dart';
import 'tokens.dart';
import 'video.dart';
import 'webfetch.dart';

class Studio extends ChangeNotifier {
  Studio(this.store, {this.shareFile = shareWithSystem});
  final LocalStore store;
  final ShareFile shareFile;
  ServiceConfig config = const ServiceConfig();
  String key = '', imageKey = '', videoKey = '', session = '', theme = 'system';

  /// `system` follows the device language; otherwise one of [Strings.names]'
  /// keys. Kept separate from the locale the app is actually rendering in.
  String languageSetting = 'system';
  bool ready = false, onboarding = true, busy = false, reduceMotion = false;
  String? error;

  /// The raw reason behind [error] — an HTTP status plus a body snippet — so a
  /// failure can be told apart instead of every 4xx looking identical. Shown as
  /// a secondary line under the localized message.
  String? errorDetail;
  String stage = 'working';

  /// The tool running right now, so a screen that watches the Agent build
  /// something can say what it is waiting for instead of a generic spinner.
  String? runningTool;

  /// Set when the model asked the user a question: the turn stops after that
  /// tool result, and the user's next message is the answer.
  bool _asked = false;
  List<Asset> gallery = [], galleryRefs = [], agentRefs = [];

  /// Files the user imported for the next message. Their text is folded into
  /// that message when it is sent, so the transcript keeps the source and the
  /// model sees it again on every later request.
  List<ImportedDocument> documents = [];
  List<ChatEntry> chat = [];
  List<ImageJob> jobs = [];
  Set<String> favorites = {};
  ImageOptions imageOptions = const ImageOptions();

  /// Video settings: the model id, the endpoint path it is asked at, and the
  /// parameters the next clip is submitted with. Kept next to the image
  /// options so both live in the same saved settings.
  VideoOptions videoOptions = const VideoOptions();
  String videoModel = videoModels.first.id;
  String videoPath = 'videos';
  List<Asset> videos = [];

  /// Style packs the user wrote, in the order they were added.
  List<ImageStyle> customStyles = const [];
  CancelToken? _cancel;
  StudioApi? _api;
  Map<String, dynamic> _conversationSettings = {};
  Future<void> _favoriteUpdates = Future<void>.value();

  /// Job ids whose row was deleted while the request was still in flight. The
  /// completion handler has already read its own state by then, so the id is
  /// remembered to keep it from writing the deleted row back.
  final _deletedJobs = <String>{};

  /// The job whose request is in flight. A download retry keeps its row in the
  /// failed/unknown state, so the state alone cannot tell whether cancelling it
  /// is safe.
  String? _activeJob;

  /// The summary of the turns that no longer fit into the request window, and
  /// how many messages of [chat] it covers. Kept for this conversation only:
  /// it is a request optimisation, not something the transcript displays.
  String? _summary;
  int _summaryUpTo = 0;

  /// Roughly how many tokens the tool schemas cost on every request. Counted
  /// once because the list is constant.
  static final int _toolTokens = estimateTokens(jsonEncode(agentTools));

  /// The turn arriving right now, so a reply can be read while it is written
  /// instead of appearing all at once when it ends.
  String streamingText = '', streamingReasoning = '';
  DateTime _streamTick = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  void _stream(AgentDelta delta) {
    streamingText += delta.text;
    streamingReasoning += delta.reasoning;
    // Repainting for every fragment of a fast stream is what makes a phone
    // stutter, so the display refreshes at a fixed rate instead.
    final now = DateTime.now();
    if (now.difference(_streamTick).inMilliseconds < 80) return;
    _streamTick = now;
    notifyListeners();
  }

  void _clearStream() {
    streamingText = '';
    streamingReasoning = '';
    _streamTick = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  ServiceConfig get activeConfig => config.copyWith(
    agentModel: _conversationSettings['agentModel'] as String?,
    imageModel: _conversationSettings['imageModel'] as String?,
  );
  AgentOptions get agentOptions {
    final profiles = _conversationSettings['agentProfiles'] as Map?;
    final value = profiles?[activeConfig.agentModel];
    return value is Map
        ? AgentOptions.fromJson(Map<String, dynamic>.from(value))
        : activeConfig.agentOptions;
  }

  Future<void> _loadConversationSettings() async {
    _conversationSettings = Map<String, dynamic>.from(
      jsonDecode(await store.setting('conversation:$session') ?? '{}') as Map,
    );
  }

  Future<void> _saveConversationSettings(Map<String, dynamic> value) async {
    await store.setSetting('conversation:$session', jsonEncode(value));
    _conversationSettings = value;
    notifyListeners();
  }

  Future<void> switchModel(String model, {required bool agent}) async {
    if (busy) return;
    if (model.trim().isEmpty) {
      throw FormatException(agent ? 'missingAgentModel' : 'missingImageModel');
    }
    await _saveConversationSettings({
      ..._conversationSettings,
      agent ? 'agentModel' : 'imageModel': model.trim(),
    });
  }

  Future<void> setAgentOptions(AgentOptions value) async {
    if (busy) return;
    value.validate(config.protocol);
    await _saveConversationSettings({
      ..._conversationSettings,
      'agentProfiles': {
        ...?_conversationSettings['agentProfiles'] as Map?,
        activeConfig.agentModel: value.toJson(),
      },
    });
  }

  Future<void> resetConversationOptions() async {
    if (busy) return;
    await _saveConversationSettings({});
  }

  Future<void> initialize() async {
    config = await store.config();
    key = await store.apiKey();
    imageKey = await store.imageKey();
    videoKey = await store.videoKey();
    final storedLanguage = await store.setting('language') ?? 'system';
    languageSetting =
        storedLanguage == 'system' || Strings.isSupported(storedLanguage)
        ? storedLanguage
        : 'system';
    theme = await store.setting('theme') ?? 'system';
    reduceMotion = await store.setting('reduceMotion') == 'true';
    onboarding = await store.setting('onboardingVersion') == null;
    session = await store.setting('currentSession') ?? store.newId();
    await store.setSetting('currentSession', session);
    // A job that was mid-submission when the process died may still be running
    // on the service. Say so at startup, before another paid request is sent.
    await store.recoverJobs();
    favorites = Set<String>.from(
      jsonDecode(await store.setting('favorites') ?? '[]') as List,
    );
    imageOptions = ImageOptions.fromJson(
      jsonDecode(await store.setting('imageOptions') ?? '{}')
          as Map<String, dynamic>,
    );
    customStyles = _parseStyles(await store.setting('imageStyles'));
    // The style used to be an option here; `/style` now writes the words into
    // the prompt, so a value saved by an older build would append them twice.
    imageOptions = imageOptions.copyWith(style: '');
    videoOptions = VideoOptions.fromJson(
      jsonDecode(await store.setting('videoOptions') ?? '{}')
          as Map<String, dynamic>,
    );
    videoModel = await store.setting('videoModel') ?? videoModels.first.id;
    videoPath = await store.setting('videoPath') ?? 'videos';
    await _loadConversationSettings();
    await _loadDecks();
    await refresh();
    await _restoreAgentReferences();
    ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    final assets = await store.assets();
    gallery = assets
        .where((a) => a.prompt.isNotEmpty && a.mime.startsWith('image/'))
        .toList();
    videos = assets.where((a) => a.mime.startsWith('video/')).toList();
    chat = await store.messages(session);
    // Video rows keep their place in the database, but the unfinished-jobs
    // list belongs to the image path: retrying a clip with image options would
    // resubmit it to the wrong endpoint.
    jobs = (await store.jobs())
        .where((job) => job.record['kind'] != 'video')
        .toList();
    notifyListeners();
  }

  Future<void> setVideoOptions(VideoOptions value) async {
    value.validate();
    videoOptions = value;
    await store.setSetting('videoOptions', jsonEncode(value.toJson()));
    notifyListeners();
  }

  Future<void> setVideoModel(String value) async {
    videoModel = value.trim();
    await store.setSetting('videoModel', videoModel);
    notifyListeners();
  }

  Future<void> setVideoPath(String value) async {
    videoPath = value.trim().isEmpty ? 'videos' : value.trim();
    await store.setSetting('videoPath', videoPath);
    notifyListeners();
  }

  /// Submits a clip, polls until the service finishes it, then stores the file
  /// beside the pictures. The record is written before the request leaves, so
  /// a process that dies mid-render leaves a row saying what was paid for.
  Future<void> submitVideo(String prompt, VideoOptions options) async {
    if (busy) return;
    options.validate();
    if (prompt.trim().isEmpty) throw const FormatException('emptyPrompt');
    if (videoModel.trim().isEmpty) {
      throw const FormatException('missingVideoModel');
    }
    final client = api;
    final model = videoModel.trim();
    final path = videoPath.trim().isEmpty ? 'videos' : videoPath.trim();
    final refs = galleryRefs.take(1).toList();
    final record = <String, dynamic>{
      'kind': 'video',
      'prompt': prompt,
      'model': model,
      'path': path,
      ...options.toJson(),
      'references': refs.map((asset) => asset.id).toList(),
    };
    busy = true;
    error = null;
    errorDetail = null;
    stage = 'working';
    _cancel = CancelToken();
    _api = client;
    final jobId = store.newId();
    notifyListeners();
    try {
      await store.job(jobId, 'submitting', record);
      final id = await client.startVideo(
        model,
        // The style words belong to this request only; the saved clip keeps
        // the prompt the user actually wrote.
        videoPrompt(prompt, options, customStyles),
        refs,
        options,
        path,
        _cancel!,
      );
      await store.job(jobId, 'rendering', {...record, 'task': id});
      var task = VideoTask(id: id, state: 'pending');
      final deadline = DateTime.now().add(const Duration(minutes: 30));
      while (!task.done && !task.failed) {
        if (DateTime.now().isAfter(deadline)) {
          throw const FormatException('videoTimeout');
        }
        await Future<void>.delayed(const Duration(seconds: 5));
        task = await client.pollVideo(id, path, _cancel!);
      }
      if (task.failed) {
        throw FormatException(
          task.message.isEmpty ? 'videoFailed' : task.message,
        );
      }
      final bytes = await client.downloadVideo(id, path, task.url, _cancel!);
      final asset = await store.saveVideo(
        bytes,
        prompt: prompt,
        parameters: {...record, 'task': id},
      );
      await store.job(jobId, 'complete', {...record, 'task': id, 'asset': asset.id});
      await refresh();
    } catch (e) {
      error = errorCode(e, submitted: true);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      await store.job(jobId, 'failed', record);
    } finally {
      busy = false;
      stage = 'working';
      _cancel = null;
      client.close();
      if (_api == client) _api = null;
      notifyListeners();
    }
  }

  Future<void> skipOnboarding() async {
    await store.setSetting('onboardingVersion', '1');
    onboarding = false;
    notifyListeners();
  }

  Future<void> saveSettings(
    ServiceConfig value,
    String apiKey,
    String pictureKey,
    String clipKey,
    String locale,
    String appearance,
    bool motion,
  ) async {
    if (busy) return;
    if (value.baseUrl.isNotEmpty) value.endpoint('models');
    if (value.imageBaseUrl.isNotEmpty) value.imageEndpoint('models');
    if (value.videoBaseUrl.isNotEmpty) value.videoEndpoint('models');
    for (final options in value.agentProfiles.values) {
      options.validate(value.protocol);
    }
    final probe = networkClient(value.proxy);
    probe.close();
    final language = locale == 'system' || Strings.isSupported(locale)
        ? locale
        : 'system';
    await store.saveConfig(
      value,
      apiKey.trim(),
      pictureKey.trim(),
      clipKey.trim(),
    );
    await store.setSetting('language', language);
    await store.setSetting('theme', appearance);
    await store.setSetting('reduceMotion', motion.toString());
    config = value;
    key = apiKey.trim();
    imageKey = pictureKey.trim();
    videoKey = clipKey.trim();
    languageSetting = language;
    theme = appearance;
    reduceMotion = motion;
    onboarding = false;
    notifyListeners();
  }

  StudioApi get api =>
      StudioApi(activeConfig, key, imageKey, store, videoKey: videoKey);

  Future<void> pickReferences(bool agent) async {
    if (busy) return;
    final selected = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
      ],
    );
    final refs = agent ? agentRefs : galleryRefs;
    if (refs.length + selected.length > config.maxReferences) {
      throw const FormatException('referenceLimit');
    }
    // Read and check every file before writing any of them: a file that turns
    // out to be too large or not an image must not leave the earlier ones
    // behind as assets nothing in the UI can reach.
    final payloads = <Uint8List>[];
    for (final file in selected) {
      if (await file.length() > StudioApi.maxImageBytes) {
        throw const FormatException('imageTooLarge');
      }
      final bytes = await file.readAsBytes();
      sniffMime(bytes);
      payloads.add(bytes);
    }
    for (final bytes in payloads) {
      refs.add(await store.saveAsset(bytes));
    }
    notifyListeners();
  }

  /// Imports files for the Agent: pictures join the references, text and
  /// Office documents are read now so the next message carries their content.
  Future<void> importFiles() async {
    if (busy) return;
    final selected = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
        const XTypeGroup(
          label: 'Files',
          extensions: [
            'txt', 'md', 'markdown', 'rst', 'log', 'csv', 'tsv', 'json', //
            'jsonl', 'toml', 'yaml', 'yml', 'ini', 'conf', 'properties',
            'xml', 'html', 'htm', 'css', 'dart', 'js', 'jsx', 'ts', 'tsx',
            'py', 'java', 'kt', 'kts', 'swift', 'go', 'rs', 'c', 'h', 'cc',
            'cpp', 'hpp', 'cs', 'rb', 'php', 'sh', 'bash', 'zsh', 'bat',
            'ps1', 'sql', 'tex', 'srt', 'vtt', 'docx', 'pptx', 'xlsx',
          ],
          mimeTypes: [
            'text/*',
            'application/json',
            'application/xml',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ],
        ),
      ],
    );
    if (selected.isEmpty) return;
    final documentCount = selected
        .where((file) => !DocumentImport.isImage(file.name))
        .length;
    if (documents.length + documentCount > DocumentImport.maxFiles) {
      throw const FormatException('documentLimit');
    }
    // Everything is checked and decoded before anything is kept, so a bad file
    // in the middle does not leave half an import behind.
    final images = <Uint8List>[];
    final added = <ImportedDocument>[];
    for (final file in selected) {
      final size = await file.length();
      if (DocumentImport.isImage(file.name)) {
        if (size > StudioApi.maxImageBytes) {
          throw const FormatException('imageTooLarge');
        }
        final bytes = await file.readAsBytes();
        sniffMime(bytes);
        images.add(bytes);
        continue;
      }
      if (!DocumentImport.isDocument(file.name)) {
        throw const FormatException('unsupportedFile');
      }
      if (size > DocumentImport.maxBytes) {
        throw const FormatException('documentTooLarge');
      }
      added.add(
        DocumentImport.read(file.name, await file.readAsBytes()),
      );
    }
    if (agentRefs.length + images.length > config.maxReferences) {
      throw const FormatException('referenceLimit');
    }
    final total = documents.fold<int>(0, (sum, doc) => sum + doc.text.length);
    if (total + added.fold<int>(0, (sum, doc) => sum + doc.text.length) >
        DocumentImport.totalCharacters) {
      throw const FormatException('documentLimit');
    }
    for (final bytes in images) {
      agentRefs.add(await store.saveAsset(bytes));
    }
    documents.addAll(added);
    notifyListeners();
  }

  /// Opens a .pptx the user already has as an editable deck in this session.
  /// Pictures are copied into the asset store, because the deck model only
  /// names images and the export resolves those names later.
  Future<Deck?> importDeck() async {
    if (busy) return null;
    final selected = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'PowerPoint',
          extensions: ['pptx'],
          mimeTypes: [
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          ],
        ),
      ],
    );
    if (selected.isEmpty) return null;
    final file = selected.first;
    if (await file.length() > 40 * 1024 * 1024) {
      throw const FormatException('deckTooLarge');
    }
    final imported = PptxImport.read(
      file.name,
      await file.readAsBytes(),
      id: store.newId(),
    );
    final assets = <String, String>{};
    for (final entry in imported.media.entries) {
      assets[entry.key] = (await store.saveAsset(entry.value)).id;
    }
    final deck = Deck(
      id: imported.deck.id,
      title: imported.deck.title,
      aspectRatio: imported.deck.aspectRatio,
      slides: [
        for (final slide in imported.deck.slides)
          Slide(
            title: slide.title,
            bullets: slide.bullets,
            bulletLevels: slide.bulletLevels,
            notes: slide.notes,
            imageId: slide.imageId,
            backgroundImageId: slide.backgroundImageId,
            backgroundColor: slide.backgroundColor,
            tables: slide.allTables,
            chart: slide.chart,
            elements: [
              for (final element in slide.elements)
                element.imageId != null && assets.containsKey(element.imageId)
                    ? element.withImage(assets[element.imageId]!)
                    : element,
            ],
          ),
      ],
    );
    decks[deck.id] = deck;
    activeDeck = deck;
    _persistDeck(deck);
    notifyListeners();
    return deck;
  }

  void removeDocument(int index) {
    if (busy) return;
    documents.removeAt(index);
    notifyListeners();
  }

  void removeReference(bool agent, int index) {
    if (busy) return;
    (agent ? agentRefs : galleryRefs).removeAt(index);
    notifyListeners();
  }

  void useReference(Asset asset, bool agent) {
    if (busy) return;
    if (agent) {
      agentRefs = [asset];
    } else {
      galleryRefs = [asset];
    }
    notifyListeners();
  }

  Future<void> newConversation() async {
    if (busy) return;
    session = store.newId();
    await store.setSetting('currentSession', session);
    _conversationSettings = {};
    chat = [];
    agentRefs = [];
    documents = [];
    // Decks are stored per conversation; a fresh one starts without any.
    decks.clear();
    activeDeck = null;
    _resetCompaction();
    notifyListeners();
  }

  Future<List<Map<String, Object?>>> conversations() => store.db.rawQuery(
    'SELECT session, MIN(id) AS first_id FROM messages GROUP BY session ORDER BY first_id DESC',
  );

  Future<void> switchConversation(String id) async {
    if (busy) return;
    session = id;
    await store.setSetting('currentSession', id);
    await _loadConversationSettings();
    chat = await store.messages(session);
    await _restoreAgentReferences();
    documents = [];
    await _loadDecks();
    _resetCompaction();
    notifyListeners();
  }

  /// Restores the decks written in this conversation. The newest becomes the
  /// active one, so the workspace button keeps working after a restart.
  Future<void> _loadDecks() async {
    decks
      ..clear()
      ..addEntries(
        (await store.decks(session)).map((deck) => MapEntry(deck.id, deck)),
      );
    activeDeck = decks.isEmpty ? null : decks.values.last;
  }

  /// Makes an older deck the workspace target, so the app bar and the preview
  /// agree after the user picks one from the deck list.
  void openDeck(Deck deck) {
    activeDeck = deck;
    notifyListeners();
  }

  /// Saves the deck in the app's private database. A deck tool returns as soon
  /// as the in-memory model changes; the write must not block the tool loop or
  /// the next request, so it runs in the background.
  void _persistDeck(Deck deck) {
    unawaited(store.saveDeck(deck, session).catchError((Object _) {}));
  }

  void _resetCompaction() {
    _summary = null;
    _summaryUpTo = 0;
  }

  Future<void> _restoreAgentReferences() async {
    agentRefs = [];
    if (!activeConfig.vision) return;
    for (final entry in chat.reversed) {
      if (entry.role == 'assistant' && entry.assetIds.isNotEmpty) {
        final asset = await store.asset(entry.assetIds.first);
        if (asset != null) agentRefs = [asset];
        break;
      }
    }
  }

  Future<void> setImageOptions(ImageOptions value) async {
    value.validate();
    if (value.style.isNotEmpty && styleFor(value.style) == null) {
      // The pack was deleted while it was selected; fall back to no style
      // rather than sending a prompt nobody asked for.
      value = value.copyWith(style: '');
    }
    await store.setSetting('imageOptions', jsonEncode(value.toJson()));
    imageOptions = value;
    notifyListeners();
  }

  /// The style with [id], built-in or custom. Null means "no style".
  ImageStyle? styleFor(String id) => styleById(customStyles, id);

  Future<void> saveStyle(ImageStyle style) => _writeStyles([
    for (final item in customStyles)
      if (item.id != style.id) item,
    style,
  ]);

  Future<void> removeStyle(String id) async {
    await _writeStyles([
      for (final item in customStyles)
        if (item.id != id) item,
    ]);
    if (imageOptions.style == id) {
      await setImageOptions(imageOptions.copyWith(style: ''));
    }
  }

  Future<void> _writeStyles(List<ImageStyle> next) async {
    await store.setSetting(
      'imageStyles',
      jsonEncode([for (final item in next) item.toJson()]),
    );
    customStyles = next;
    notifyListeners();
  }

  /// Reads the saved packs, dropping any entry the current validation rejects
  /// so one bad row cannot stop the app from starting.
  static List<ImageStyle> _parseStyles(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final styles = <ImageStyle>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      try {
        styles.add(ImageStyle.fromJson(Map<String, dynamic>.from(item)));
      } on FormatException {
        continue;
      }
    }
    return styles;
  }

  Future<void> toggleFavorite(Asset asset) {
    // Each toggle must read the result of the preceding write, including when
    // multiple taps arrive before SQLite has completed its first operation.
    final update = _favoriteUpdates.then((_) async {
      final next = {...favorites};
      if (!next.add(asset.id)) next.remove(asset.id);
      await store.setSetting('favorites', jsonEncode(next.toList()));
      favorites = next;
      notifyListeners();
    });
    // A failed write still reaches its caller, while the queue remains usable.
    _favoriteUpdates = update.catchError((Object _) {});
    return update;
  }

  /// Removes the image from the Gallery and from anything still naming it. The
  /// file goes with the row; a chat bubble that mentioned it shows the
  /// broken-image placeholder instead of bringing the asset back.
  Future<void> deleteAsset(Asset asset) async {
    if (busy) throw const FormatException('deleteWhileBusy');
    await store.deleteAsset(asset.id);
    gallery.removeWhere((item) => item.id == asset.id);
    galleryRefs.removeWhere((item) => item.id == asset.id);
    agentRefs.removeWhere((item) => item.id == asset.id);
    // Removal goes through the same queue as a favorite toggle; otherwise a
    // toggle that started earlier can write the deleted id back afterwards.
    final update = _favoriteUpdates.then((_) async {
      if (favorites.remove(asset.id)) {
        await store.setSetting('favorites', jsonEncode(favorites.toList()));
      }
    });
    _favoriteUpdates = update.catchError((Object _) {});
    notifyListeners();
    await update;
  }

  Future<void> deleteJob(ImageJob job) async {
    // A job with a request in flight names paid work; deleting it without
    // stopping that request would leave the work running with no record.
    if (busy && _activeJob == job.id) cancel();
    _deletedJobs.add(job.id);
    if (_activeJob == job.id) _activeJob = null;
    await store.deleteJob(job.id);
    jobs.removeWhere((item) => item.id == job.id);
    notifyListeners();
  }

  /// Writes a job state unless the record was deleted while its request was in
  /// flight. Without this the catch/finally path of a cancelled turn would
  /// restore the row the user just removed.
  Future<void> _recordJob(
    String id,
    String state,
    Map<String, dynamic> record,
  ) async {
    if (_deletedJobs.contains(id)) return;
    if (state == 'submitting') {
      _activeJob = id;
    } else if (_activeJob == id) {
      _activeJob = null;
    }
    await store.job(id, state, record);
  }

  static const _summaryPrompt =
      'You condense a long conversation so another assistant can continue it. '
      'Reply with the summary only and do not call any tool. Write in the '
      'language the conversation mostly uses. Keep facts, names, numbers, '
      'user constraints, decisions and unfinished work; drop pleasantries and '
      'repeated tool output. Use these headings: Objective, Requirements and '
      'constraints, Decisions, Done, In progress, Next steps, Relevant files '
      'or ids.';

  /// Prepares the history for one request. Below the user's token limit the
  /// conversation goes out untouched. Near it, older turns are replaced by a
  /// summary written by the same model, while the newest window stays verbatim,
  /// so tool pairing and recent wording survive.
  Future<({List<ChatEntry> history, AgentOptions options})> _prepareRequest(
    StudioApi client,
    AgentOptions options,
  ) async {
    final limit = options.contextTokens;
    final summary = _summary;
    if (limit <= 0) {
      // A manual /compact checkpoint has to survive the automatic limit being
      // off: fold it in and send everything after it.
      if (summary == null || summary.isEmpty) {
        return (history: chat, options: options);
      }
      return (
        history: chat.sublist(math.min(_summaryUpTo, chat.length)),
        options: _withSummary(options, summary),
      );
    }
    final reserve = math.max(2048, (limit * .15).round());
    final output =
        options.maxOutputTokens ??
        (client.config.protocol == ApiProtocol.anthropic ? 2048 : 1024);
    final budget = math.max(512, limit - reserve - output);
    final keep = math.min(15000, math.max(2000, limit ~/ 4));

    int cost(List<ChatEntry> history, AgentOptions settings) =>
        estimateTokens(settings.requestPrompt) +
        _toolTokens +
        estimateHistoryTokens(history) +
        8;

    if (_summary == null && cost(chat, options) <= budget) {
      return (history: chat, options: options);
    }

    var start = _splitForKeep(chat, keep);
    // The newest message is always sent verbatim: summarizing it would leave
    // the request without the instruction it exists to answer.
    if (chat.isNotEmpty) start = math.min(start, chat.length - 1);
    // A previous checkpoint may sit later than today's keep window; reusing it
    // avoids summarizing the same turns twice.
    if (_summaryUpTo > start && _summaryUpTo < chat.length) {
      start = _summaryUpTo;
    }
    while (start < chat.length - 1 && chat[start].role != 'user') {
      start++;
    }

    if (start > 0 && (_summary == null || start > _summaryUpTo)) {
      final from = _summaryUpTo <= chat.length ? _summaryUpTo : 0;
      final covered = chat.sublist(from, start);
      if (covered.isNotEmpty) {
        final previous = _summary == null
            ? ''
            : 'Previous summary:\n$_summary\n\n';
        stage = 'compacting';
        notifyListeners();
        try {
          final result = await client.converse(
            [ChatEntry('user', '$previous${_transcript(covered)}')],
            const [],
            _cancel!,
            options: const AgentOptions(
              systemPrompt: _summaryPrompt,
              maxOutputTokens: 3000,
            ),
          );
          final text = result.text.trim();
          if (text.isNotEmpty) {
            _summary = text;
            _summaryUpTo = start;
          }
        } catch (error) {
          // Stopping is the user's decision and must end the turn. Any other
          // summary failure falls back to trimming below, so a long
          // conversation still gets an answer.
          if (error is DioException && CancelToken.isCancel(error)) rethrow;
        } finally {
          stage = 'discussing';
          notifyListeners();
        }
      }
    }

    var send = chat.sublist(math.min(start, chat.length));
    var settings = options;
    // Read the checkpoint again: the block above may have just written one.
    final checkpoint = _summary;
    if (checkpoint != null && checkpoint.isNotEmpty) {
      settings = _withSummary(settings, checkpoint);
    }
    // Even a summary plus the newest window can exceed a very small limit; drop
    // whole turns from the front, never the newest message.
    while (send.length > 1 && cost(send, settings) > budget) {
      var drop = 1;
      while (drop < send.length && send[drop].role != 'user') {
        drop++;
      }
      if (drop >= send.length) drop = send.length - 1;
      send = send.sublist(drop);
      // A tool result whose assistant call was just dropped cannot be sent on
      // its own; the next request would be rejected for pairing.
      while (send.length > 1 && send.first.role == 'tool') {
        send = send.sublist(1);
      }
    }
    return (history: send, options: settings);
  }

  /// Folds the checkpoint into the system prompt, keeping the user's own
  /// standing instructions first.
  AgentOptions _withSummary(AgentOptions settings, String summary) {
    final user = settings.systemPrompt.trim();
    return settings.copyWith(
      systemPrompt: [
        if (user.isNotEmpty) user,
        '[Summary of the earlier conversation, condensed because the context '
            'window is nearly full]\n$summary',
      ].join('\n\n'),
    );
  }

  /// The manual `/compact` command: summarize everything before the newest
  /// turn and keep that turn verbatim. Unlike the automatic pass it does not
  /// depend on `contextTokens`, works on a short history, and reports how many
  /// messages it folded away.
  ///
  /// The local transcript is untouched — compaction is lossy for the model,
  /// not for the user — and the checkpoint applies to the next request.
  Future<({int compacted, int kept})> compactNow() async {
    if (busy) throw const FormatException('busy');
    if (chat.isEmpty) throw const FormatException('compactEmpty');
    var start = chat.length - 1;
    while (start > 0 && chat[start].role != 'user') {
      start--;
    }
    // Nothing older than the newest user turn means there is nothing to fold.
    if (start <= 0 || chat[start].role != 'user') {
      throw const FormatException('compactEmpty');
    }
    final client = api;
    final requestConfig = client.config;
    final options = agentOptions;
    busy = true;
    error = null;
    errorDetail = null;
    stage = 'compacting';
    _cancel = CancelToken();
    _api = client;
    notifyListeners();
    try {
      options.validate(requestConfig.protocol);
      if (key.isEmpty) throw const FormatException('missingKey');
      if (requestConfig.agentModel.trim().isEmpty) {
        throw const FormatException('missingAgentModel');
      }
      requestConfig.endpoint(requestConfig.protocol.chatPath);
      final from = math.min(_summaryUpTo, start);
      final covered = chat.sublist(from, start);
      final previous = _summary == null
          ? ''
          : 'Previous summary:\n$_summary\n\n';
      final result = await client.converse(
        [ChatEntry('user', '$previous${_transcript(covered)}')],
        const [],
        _cancel!,
        options: const AgentOptions(
          systemPrompt: _summaryPrompt,
          maxOutputTokens: 3000,
        ),
      );
      final text = result.text.trim();
      if (text.isEmpty) throw const FormatException('compactFailed');
      _summary = text;
      _summaryUpTo = start;
      return (compacted: covered.length, kept: chat.length - start);
    } finally {
      client.close();
      _api = null;
      _cancel = null;
      busy = false;
      stage = 'discussing';
      notifyListeners();
    }
  }

  /// Index where the verbatim window starts: as many newest messages as fit in
  /// [keepTokens], moved back to a user turn so no tool result is separated
  /// from the assistant call that produced it.
  int _splitForKeep(List<ChatEntry> history, int keepTokens) {
    var tokens = 0;
    var start = history.length;
    while (start > 0) {
      final next = estimateHistoryTokens([history[start - 1]]);
      if (tokens + next > keepTokens) break;
      tokens += next;
      start--;
    }
    while (start > 0 && start < history.length && history[start].role != 'user') {
      start--;
    }
    return start;
  }

  String _transcript(Iterable<ChatEntry> entries) => entries.map((entry) {
    final calls = entry.calls.isEmpty
        ? ''
        : '\nCalls: ${entry.calls.map((call) => '${call.name}(${jsonEncode(call.arguments)})').join('; ')}';
    final label = entry.role == 'tool'
        ? 'Tool result${entry.name == null ? '' : ' (${entry.name})'}'
        : entry.role;
    final thought = entry.reasoning.isEmpty
        ? ''
        : '\nThinking: ${entry.reasoning}';
    return '$label: ${entry.text}$calls$thought';
  }).join('\n\n');

  Future<void> submit(
    String prompt,
    bool agent,
    ImageOptions options, {
    VoidCallback? onAccepted,
  }) async {
    if (busy) return;
    // Imported files become part of the message, so a later request replays the
    // source along with the question that referred to it.
    final message = agent
        ? DocumentImport.compose(prompt, documents)
        : prompt.trim();
    if (message.isEmpty) throw const FormatException('emptyPrompt');
    final refs = List<Asset>.of(agent ? agentRefs : galleryRefs);
    final client = api;
    final requestConfig = client.config;
    final requestAgentOptions = agentOptions;
    try {
      options.validate();
      if (!agent) {
        client.validateGeneration(prompt, refs, options);
      } else {
        requestAgentOptions.validate(requestConfig.protocol);
        if (key.isEmpty) throw const FormatException('missingKey');
        if (requestConfig.agentModel.trim().isEmpty) {
          throw const FormatException('missingAgentModel');
        }
        requestConfig.endpoint(requestConfig.protocol.chatPath);
        if (refs.isNotEmpty && !config.vision) {
          throw const FormatException('visionDisabled');
        }
      }
    } catch (_) {
      client.close();
      rethrow;
    }
    busy = true;
    error = null;
    errorDetail = null;
    _asked = false;
    stage = agent ? 'discussing' : 'working';
    _cancel = CancelToken();
    _api = client;
    String? jobId;
    Map<String, dynamic>? record;
    final created = <Asset>[];
    var answerSaved = false;
    // Hold the process while the turn runs, so swiping the task away does not
    // stop the work; the service is stopped in the finally below.
    unawaited(
      Background.begin(
        title: _backgroundString('turnRunning'),
        body: _cut(message),
      ),
    );
    notifyListeners();
    try {
      String? imagePrompt = message;
      String reply = '';
      String reasoning = '';
      // What the gallery path asks the image service for. The Agent derives
      // its options per call, from the ratio that call carries.
      final jobOptions = options;
      if (agent) {
        await store.addMessage(
          session,
          ChatEntry(
            'user',
            message,
            assetIds: refs.map((a) => a.id).toList(),
          ),
        );
        documents = [];
        onAccepted?.call();
        chat = await store.messages(session);
        notifyListeners();
        // One turn is not one request: the model may call a tool, read the
        // result and decide to call another. The cap keeps a loop that never
        // settles from spending the whole session.
        // A page with a table takes add_slide + add_table. Allow a normal
        // multi-page deck to finish while retaining a finite request budget.
        const maxSteps = 32;
        for (var step = 0; step < maxSteps; step++) {
          // The last request is a wrap-up: tools are left out, so the model has
          // to say what it finished and what is left instead of starting a call
          // the loop would cut off without an answer.
          final wrapUp = step == maxSteps - 1;
          final stepOptions = wrapUp
              ? requestAgentOptions.copyWith(
                  systemPrompt:
                      '${requestAgentOptions.systemPrompt}\n\n'
                      '[Turn budget reached: you cannot call more tools. '
                      'Summarize what you completed and what remains, then stop.]',
                )
              : requestAgentOptions;
          final prepared = await _prepareRequest(client, stepOptions);
          final result = requestConfig.streamAgent
              ? await client.converseStream(
                  prepared.history,
                  refs,
                  _cancel!,
                  options: prepared.options,
                  allowTools: !wrapUp,
                  onDelta: _stream,
                )
              : await client.converse(
                  prepared.history,
                  refs,
                  _cancel!,
                  options: prepared.options,
                  allowTools: !wrapUp,
                );
          reply = result.text;
          reasoning = result.reasoning;
          if (wrapUp || result.calls.isEmpty) break;
          await store.addMessage(
            session,
            ChatEntry(
              'assistant',
              result.text,
              model: requestConfig.agentModel,
              reasoning: result.reasoning,
              calls: result.calls,
            ),
          );
          chat = await store.messages(session);
          _clearStream();
          for (var index = 0; index < result.calls.length; index++) {
            final call = result.calls[index];
            String output;
            try {
              output = await _runCall(
                client,
                call,
                refs,
                options,
                created,
                onJob: (id, row) {
                  jobId = id;
                  record = row;
                },
              );
            } catch (e) {
              // A tool failure is a result for the model, not the end of the
              // turn. Cancellation is the one exception: the user asked to
              // stop, so the turn ends.
              await store.addMessage(
                session,
                ChatEntry(
                  'tool',
                  'Tool failed: ${errorCode(e)}',
                  callId: call.id,
                  name: call.name,
                ),
              );
              chat = await store.messages(session);
              if (errorCode(e) == 'cancelled') rethrow;
              continue;
            }
            await store.addMessage(
              session,
              ChatEntry('tool', output, callId: call.id, name: call.name),
            );
            chat = await store.messages(session);
            if (_asked) {
              // A question ends the turn. The calls behind it were named by
              // the assistant message too, so answer them before stopping.
              for (final rest in result.calls.skip(index + 1)) {
                await store.addMessage(
                  session,
                  ChatEntry(
                    'tool',
                    'Not run: the user was asked a question and the turn ended.',
                    callId: rest.id,
                    name: rest.name,
                  ),
                );
              }
              chat = await store.messages(session);
              break;
            }
          }
          if (_asked) break;
        }
        // Every image above was produced by a call; the single-shot path below
        // belongs to the gallery.
        imagePrompt = null;
      }
      final galleryPrompt = imagePrompt;
      if (galleryPrompt != null) {
        stage = 'working';
        notifyListeners();
        client.validateGeneration(galleryPrompt, refs, jobOptions);
        final candidateJobId = store.newId();
        // `jobId` and `record` are written from inside the loop's callback, so
        // Dart never promotes them to non-null. The row and its id stay local
        // here and are only copied out for the catch block.
        final row = <String, dynamic>{
          'prompt': galleryPrompt,
          'references': refs.map((a) => a.id).toList(),
          'model': requestConfig.imageModel,
          ...jobOptions.toJson(),
          'createdAt': DateTime.now().toIso8601String(),
          'session': agent ? session : null,
        };
        record = row;
        await _recordJob(candidateJobId, 'submitting', row);
        jobId = candidateJobId;
        if (!agent) onAccepted?.call();
        jobs = await store.jobs();
        notifyListeners();
        created.addAll(
          await _runJob(
            client,
            candidateJobId,
            row,
            galleryPrompt,
            refs,
            jobOptions,
          ),
        );
      }
      if (agent) {
        _clearStream();
        if (!_asked) {
          await store.addMessage(
            session,
            ChatEntry(
              'assistant',
              reply.isEmpty && created.isNotEmpty ? '' : reply,
              model: requestConfig.agentModel,
              reasoning: reasoning,
              assetIds: created.map((a) => a.id).toList(),
            ),
          );
        }
        answerSaved = true;
        if (created.isNotEmpty && requestConfig.vision) {
          agentRefs = [created.first];
        }
      }
      await refresh();
    } catch (e) {
      error = errorCode(e, submitted: jobId != null);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      // Stopping is usually a way to get a word in, so the part that was
      // already written stays in the transcript and in the next request's
      // context instead of vanishing with the spinner.
      if (agent && !answerSaved && streamingText.trim().isNotEmpty) {
        await store.addMessage(
          session,
          ChatEntry(
            'assistant',
            streamingText,
            model: requestConfig.agentModel,
            reasoning: streamingReasoning,
            // A stopped turn keeps its text, but it is not a finished answer.
            aborted: error == 'cancelled',
          ),
        );
        chat = await store.messages(session);
      }
      final failedJob = jobId;
      if (failedJob != null) {
        final uncertain =
            error == 'unknown' ||
            error == 'cancelled' ||
            error == 'incompleteImageStream';
        await _recordJob(failedJob, uncertain ? 'unknown' : 'failed', {
          ...record!,
          'error': error,
          'detail': errorDetail,
          if (e is ImageApiException && e.outputs.isNotEmpty)
            'outputs': e.outputs,
        });
        jobs = await store.jobs();
      }
    } finally {
      client.close();
      _api = null;
      _cancel = null;
      busy = false;
      _asked = false;
      _clearStream();
      unawaited(Background.end());
      // The platform only shows this when no activity is on screen, and it
      // never posts one for a turn the user stopped on purpose.
      if (error != 'cancelled') {
        unawaited(
          Background.notify(
            title: _backgroundString(error == null ? 'turnDone' : 'turnFailed'),
            body: error == null
                ? _cut(prompt.trim())
                : _backgroundString(error!),
          ),
        );
      }
      notifyListeners();
    }
  }

  Future<void> retryDownload(ImageJob job) async {
    if (busy) return;
    final outputs = List<String>.from(job.record['outputs'] as List? ?? []);
    if (outputs.isEmpty) return;
    final client = api;
    busy = true;
    error = null;
    errorDetail = null;
    stage = 'downloading';
    _cancel = CancelToken();
    _api = client;
    _activeJob = job.id;
    notifyListeners();
    try {
      final images = await client.downloadImages(outputs, _cancel!);
      final created = <Asset>[];
      // Recovery payloads can contain large Base64 images. Once downloaded,
      // keep the saved files as the source of truth and release those copies.
      final parameters = Map<String, dynamic>.of(job.record)..remove('outputs');
      final references = List<String>.from(
        job.record['references'] as List? ?? [],
      );
      for (final bytes in images) {
        // Recovery goes through the same measurement as a fresh generation, or
        // a retried image would keep showing only the requested size.
        final actual = imageSizeOf(bytes);
        created.add(
          await store.saveAsset(
            bytes,
            prompt: job.prompt,
            parentId: references.isEmpty ? null : references.first,
            parameters: actual == null
                ? parameters
                : {...parameters, 'actualSize': actual},
          ),
        );
      }
      await _recordJob(job.id, 'complete', {
        ...parameters,
        'assets': created.map((a) => a.id).toList(),
      });
      await _attachResults(job.record, created, client.config.vision);
      await refresh();
    } catch (e) {
      error = errorCode(e);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      await _recordJob(job.id, 'failed', {
        ...job.record,
        'error': error,
        'detail': errorDetail,
      });
      jobs = await store.jobs();
    } finally {
      client.close();
      _api = null;
      _cancel = null;
      _activeJob = null;
      busy = false;
      notifyListeners();
    }
  }

  /// Decks built in this session, keyed by the id the model was given.
  final Map<String, Deck> decks = {};
  Deck? activeDeck;

  String _createDeck(AgentCall call) {
    try {
      final title = _argText(call, 'title');
      final ratio = _argText(call, 'aspect_ratio');
      if (ratio != '16:9' && ratio != '4:3') {
        return 'Invalid arguments for create_deck.';
      }
      final id = store.newId();
      final deck = Deck(id: id, title: title, aspectRatio: ratio);
      decks[id] = deck;
      activeDeck = deck;
      _persistDeck(deck);
      notifyListeners();
      return 'Deck "$title" created with id $id ($ratio).';
    } on FormatException {
      return 'Invalid arguments for create_deck.';
    }
  }

  String _addSlide(AgentCall call, List<Asset> created) {
    try {
      final deck = _deckOf(call);
      // "last" is resolved here, and an id that matches nothing is answered
      // with an error instead of silently producing a broken picture.
      final resolved = _imageArg(call, 'image_id', created);
      if (resolved.error != null) return resolved.error!;
      final image = resolved.image;
      deck.slides.add(
        Slide(
          title: _argText(call, 'title'),
          bullets: _argBullets(call),
          bulletLevels: _argLevels(call),
          imageId: image.isEmpty ? null : image,
        ),
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Slide ${deck.slides.length} added to deck ${deck.id}'
          '${image.isEmpty ? '' : ' with image $image'}.';
    } on FormatException {
      return 'Invalid arguments for add_slide.';
    }
  }

  String _updateSlide(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final previous = deck.slides[index];
      deck.slides[index] = Slide(
        title: _argText(call, 'title'),
        bullets: _argBullets(call),
        bulletLevels: _argLevels(call),
        notes: previous.notes,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: previous.chart,
        elements: previous.elements,
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Slide ${index + 1} updated.';
    } on FormatException {
      return 'Invalid arguments for update_slide.';
    }
  }

  String _removeSlide(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      deck.slides.removeAt(index);
      _persistDeck(deck);
      notifyListeners();
      return 'Slide ${index + 1} removed. ${deck.slides.length} remain.';
    } on FormatException {
      return 'Invalid arguments for remove_slide.';
    }
  }

  String _moveSlide(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final from = _argIndex(call, 'from', deck.slides.length);
      final to = _argIndex(call, 'to', deck.slides.length);
      deck.slides.insert(to, deck.slides.removeAt(from));
      _persistDeck(deck);
      notifyListeners();
      return 'Slide ${from + 1} moved to position ${to + 1}.';
    } on FormatException {
      return 'Invalid arguments for move_slide. Use two zero-based indexes '
          'inside the deck.';
    }
  }

  String _addTable(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final headerRow = call.arguments['header_row'];
      if (headerRow is! bool) throw const FormatException('invalidTool');
      final previous = deck.slides[index];
      final rawSlot = call.arguments['table_index'];
      if (rawSlot != null && rawSlot is! int) {
        throw const FormatException('invalidTool');
      }
      // Callers that send no table_index keep the old "replace what this page
      // already has" behaviour; -1 explicitly appends a second table.
      final slot = rawSlot is int
          ? rawSlot
          : (previous.allTables.isEmpty ? -1 : 0);
      final table = SlideTable.fromJson({
        'rows': call.arguments['rows'],
        'headerRow': headerRow,
      });
      final tables = List<SlideTable>.of(previous.allTables);
      if (slot >= 0 && slot < tables.length) {
        tables[slot] = table;
      } else if (slot < 0 && tables.length < Slide.maxTables) {
        tables.add(table);
      } else {
        return 'Slide ${index + 1} already has ${tables.length} tables '
            '(max ${Slide.maxTables}). Pass table_index 0 or 1 to replace '
            'one, or split the data across pages.';
      }
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        bulletLevels: previous.bulletLevels,
        notes: previous.notes,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: tables,
        chart: previous.chart,
        elements: previous.elements,
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Table ${table.rows.length}x${table.columnCount} '
          '${slot >= 0 ? 'replaced' : 'added'} on slide ${index + 1} '
          'in deck ${deck.id}.';
    } on FormatException {
      return 'Invalid arguments for add_table. Use an existing deck and '
          'zero-based slide index, table_index (-1 to append, 0 or 1 to '
          'replace), header_row as a boolean, and 1-12 rectangular rows of '
          '1-8 string cells (at most 500 characters each).';
    }
  }

  String _addChart(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final kind = call.arguments['kind'];
      final title = call.arguments['title'];
      final categories = call.arguments['categories'];
      final rawSeries = call.arguments['series'];
      final dataLabels = call.arguments['data_labels'] ?? false;
      final valueFormat = call.arguments['value_format'] ?? 'general';
      final stacked = call.arguments['stacked'] ?? false;
      if (kind is! String ||
          title is! String ||
          categories is! List ||
          rawSeries is! List ||
          dataLabels is! bool ||
          valueFormat is! String ||
          stacked is! bool) {
        throw const FormatException('invalidTool');
      }
      final labels = <String>[];
      for (final category in categories) {
        if (category is! String) throw const FormatException('invalidTool');
        labels.add(category);
      }
      final series = <ChartSeries>[];
      for (final item in rawSeries) {
        if (item is! Map) throw const FormatException('invalidTool');
        final name = item['name'];
        final values = item['values'];
        if (name is! String ||
            values is! List ||
            values.any((value) => value is! num)) {
          throw const FormatException('invalidTool');
        }
        series.add(
          ChartSeries(
            name: name,
            values: [for (final value in values) (value as num).toDouble()],
          ),
        );
      }
      final chart = SlideChart(
        kind: kind,
        title: title,
        categories: labels,
        series: series,
        dataLabels: dataLabels,
        valueFormat: valueFormat,
        stacked: stacked,
      );
      final previous = deck.slides[index];
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        bulletLevels: previous.bulletLevels,
        notes: previous.notes,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: chart,
        elements: previous.elements,
      );
      _persistDeck(deck);
      notifyListeners();
      return '${chart.kind} chart with ${chart.categories.length} categories '
          'and ${chart.series.length} series placed on slide ${index + 1}.';
    } on FormatException {
      return 'Invalid arguments for add_chart. Use an existing deck and '
          'zero-based slide index, kind bar/line/pie, a title string, 1-12 '
          'short categories and 1-3 series whose values match the categories.';
    }
  }

  String _setNotes(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final notes = _argText(call, 'notes');
      if (notes.length > Slide.maxNotesLength) {
        return 'Notes are limited to ${Slide.maxNotesLength} characters.';
      }
      final previous = deck.slides[index];
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        bulletLevels: previous.bulletLevels,
        notes: notes.trim(),
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: previous.chart,
        elements: previous.elements,
      );
      _persistDeck(deck);
      notifyListeners();
      return notes.trim().isEmpty
          ? 'Notes cleared on slide ${index + 1}.'
          : 'Notes saved on slide ${index + 1} '
                '(${notes.trim().length} characters).';
    } on FormatException {
      return 'Invalid arguments for set_notes. Use an existing deck and a '
          'zero-based slide index, with notes as a string.';
    }
  }

  String _finishDeck(AgentCall call) {
    try {
      final deck = _deckOf(call);
      deck.finished = true;
      _persistDeck(deck);
      unawaited(_snapshotDeck(deck));
      notifyListeners();
      return 'Deck ${deck.id} finished: ${deck.slides.length} slides.';
    } on FormatException {
      return 'Invalid arguments for finish_deck.';
    }
  }

  /// Applies a generated picture behind the text. An index of -1 sets the deck
  /// default; anything else touches one slide. The image has to be one this
  /// app produced, because the export resolves ids against the asset table.
  String _setBackground(AgentCall call, List<Asset> created) {
    try {
      final deck = _deckOf(call);
      final index = call.arguments['index'];
      if (index is! int || index < -1 || index >= deck.slides.length) {
        return 'Invalid index: use -1 for the whole deck or an existing '
            'zero-based slide index.';
      }
      final resolved = _imageArg(call, 'image_id', created);
      if (resolved.error != null) return resolved.error!;
      final image = resolved.image;
      // The picture wins when both are given; an empty pair clears the
      // override so the page inherits the deck again.
      final color = image.isEmpty ? _argOptional(call, 'color') : null;
      if (index == -1) {
        deck.backgroundImageId = image.isEmpty ? null : image;
        deck.backgroundColor = color;
      } else {
        final previous = deck.slides[index];
        deck.slides[index] = Slide(
          title: previous.title,
          bullets: previous.bullets,
          imageId: previous.imageId,
          // An empty pair clears this page's override, so it inherits the deck
          // background again.
          backgroundImageId: image.isEmpty ? null : image,
          backgroundColor: color,
          tables: previous.allTables,
          chart: previous.chart,
          notes: previous.notes,
          bulletLevels: previous.bulletLevels,
          elements: previous.elements,
        );
      }
      _persistDeck(deck);
      notifyListeners();
      if (image.isNotEmpty) {
        return 'Background $image applied to '
            '${index == -1 ? 'deck ${deck.id}' : 'slide ${index + 1}'}.';
      }
      if (color != null) {
        return 'Background colour $color applied to '
            '${index == -1 ? 'deck ${deck.id}' : 'slide ${index + 1}'}.';
      }
      return 'Background cleared on '
          '${index == -1 ? 'the deck' : 'slide ${index + 1}'}.';
    } on FormatException {
      return 'Invalid arguments for set_background.';
    }
  }

  /// Adds a styled, editable text box at fractional page coordinates. Elements
  /// sit on top of the standard title/bullets layout, so a page can be built
  /// from them alone (leave title and bullets empty) or decorated with them.
  String _addText(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final previous = deck.slides[index];
      if (previous.elements.length >= SlideElement.maxCount) {
        return 'Slide ${index + 1} already has ${SlideElement.maxCount} '
            'elements. Remove one with remove_element or use another page.';
      }
      final element = SlideElement(
        id: _newElementId(previous),
        kind: SlideElementKind.text,
        text: _argText(call, 'text'),
        x: _argNumber(call, 'x'),
        y: _argNumber(call, 'y'),
        width: _argNumber(call, 'width'),
        height: _argNumber(call, 'height'),
        fontSize: _argNumber(call, 'font_size'),
        color: _argText(call, 'color'),
        bold: _argBool(call, 'bold'),
        italic: _argBool(call, 'italic'),
        align: _argText(call, 'align'),
        fill: _argOptional(call, 'fill'),
        fill2: _argOptionalOrNull(call, 'fill2'),
        border: _argOptional(call, 'border'),
        radius: _argNumber(call, 'radius'),
        shadow: call.arguments['shadow'] == true,
        rotation: _argNumberOr(call, 'rotation', 0),
        letterSpacing: _argNumberOr(call, 'letter_spacing', 0),
        font: _argOptional(call, 'font'),
        padding: _optionalPadding(call),
        lineSpacing: _argNumber(call, 'line_spacing'),
      );
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: previous.chart,
        notes: previous.notes,
        bulletLevels: previous.bulletLevels,
        elements: [...previous.elements, element],
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Text element ${element.id} added to slide ${index + 1} '
          '(${_short(element.text)}).';
    } on FormatException {
      return 'Invalid arguments for add_text. Use a zero-based slide index, '
          'x/y/width/height as fractions of the page with x+width and y+height '
          'at most 1, font_size in points, RRGGBB colours, align '
          'left/center/right and radius 0-0.5. Pass an empty string for no '
          'fill or border.';
    }
  }

  /// Rewrites one existing text box in place. The geometry stays, so a model
  /// fixing a typo does not have to restate (and risk moving) the rectangle.
  String _updateText(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final previous = deck.slides[index];
      final id = _argText(call, 'element').trim();
      final position = previous.elements.indexWhere(
        (element) => element.id == id,
      );
      if (position < 0) {
        final ids = previous.elements.map((element) => element.id).join(', ');
        return 'No element "$id" on slide ${index + 1}. Existing ids: '
            '${ids.isEmpty ? 'none' : ids}.';
      }
      final old = previous.elements[position];
      if (old.kind != SlideElementKind.text) {
        return 'Element "$id" is a picture; update_text only edits text '
            'boxes. Use remove_element and add_image instead.';
      }
      final updated = SlideElement(
        id: old.id,
        kind: SlideElementKind.text,
        x: old.x,
        y: old.y,
        width: old.width,
        height: old.height,
        text: _argText(call, 'text'),
        fontSize: _argNumber(call, 'font_size'),
        color: _argText(call, 'color'),
        bold: _argBool(call, 'bold'),
        italic: _argBool(call, 'italic'),
        align: _argText(call, 'align'),
        fill: _argOptional(call, 'fill'),
        fill2: _argOptionalOrNull(call, 'fill2'),
        border: _argOptional(call, 'border'),
        radius: _argNumber(call, 'radius'),
        shadow: call.arguments['shadow'] == true,
        rotation: _argNumberOr(call, 'rotation', 0),
        letterSpacing: _argNumberOr(call, 'letter_spacing', 0),
        font: _argOptional(call, 'font'),
        padding: _optionalPadding(call),
        lineSpacing: _argNumber(call, 'line_spacing'),
      );
      final elements = [...previous.elements];
      elements[position] = updated;
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: previous.chart,
        notes: previous.notes,
        bulletLevels: previous.bulletLevels,
        elements: elements,
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Text element ${updated.id} updated on slide ${index + 1} '
          '(${_short(updated.text)}).';
    } on FormatException {
      return 'Invalid arguments for update_text. Use the element id add_text '
          'returned, and send every style field (text, font_size, color, '
          'bold, italic, align, font, padding, line_spacing, fill, border, '
          'radius) with the current value for the ones you keep.';
    }
  }

  /// Adds a generated picture as a free-form element, so one page can carry
  /// several pictures in a grid instead of the single standard image slot.
  String _addImage(AgentCall call, List<Asset> created) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final previous = deck.slides[index];
      if (previous.elements.length >= SlideElement.maxCount) {
        return 'Slide ${index + 1} already has ${SlideElement.maxCount} '
            'elements. Remove one with remove_element or use another page.';
      }
      final resolved = _imageArg(call, 'image_id', created);
      if (resolved.error != null) return resolved.error!;
      if (resolved.image.isEmpty) {
        return 'add_image needs an image_id: call generate_image first, then '
            'pass its id or "last".';
      }
      final element = SlideElement(
        id: _newElementId(previous),
        kind: SlideElementKind.image,
        imageId: resolved.image,
        x: _argNumber(call, 'x'),
        y: _argNumber(call, 'y'),
        width: _argNumber(call, 'width'),
        height: _argNumber(call, 'height'),
        fit: _argText(call, 'fit'),
        radius: _argNumber(call, 'radius'),
        border: _argOptional(call, 'border'),
      );
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: previous.chart,
        notes: previous.notes,
        bulletLevels: previous.bulletLevels,
        elements: [...previous.elements, element],
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Image element ${element.id} added to slide ${index + 1} '
          'at x=${element.x}, y=${element.y}, ${element.width}x'
          '${element.height}, fit ${element.fit}.';
    } on FormatException {
      return 'Invalid arguments for add_image. Use a zero-based slide index, '
          'an image_id returned by generate_image or "last", x/y/width/height '
          'as fractions of the page with x+width and y+height at most 1, fit '
          'cover or contain, radius 0-0.5 and an empty border for none.';
    }
  }

  String _removeElement(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final index = _argIndex(call, 'index', deck.slides.length);
      final id = _argText(call, 'element').trim();
      final previous = deck.slides[index];
      final remaining = [
        for (final element in previous.elements)
          if (element.id != id) element,
      ];
      if (remaining.length == previous.elements.length) {
        final ids = previous.elements.map((element) => element.id).join(', ');
        return 'No element "$id" on slide ${index + 1}. Existing ids: '
            '${ids.isEmpty ? 'none' : ids}.';
      }
      deck.slides[index] = Slide(
        title: previous.title,
        bullets: previous.bullets,
        imageId: previous.imageId,
        backgroundImageId: previous.backgroundImageId,
        backgroundColor: previous.backgroundColor,
        tables: previous.allTables,
        chart: previous.chart,
        notes: previous.notes,
        bulletLevels: previous.bulletLevels,
        elements: remaining,
      );
      _persistDeck(deck);
      notifyListeners();
      return 'Element $id removed from slide ${index + 1}. '
          '${remaining.length} remain.';
    } on FormatException {
      return 'Invalid arguments for remove_element.';
    }
  }

  /// Element ids only have to be unique within a slide; a short one keeps the
  /// transcript and the deck JSON readable.
  String _newElementId(Slide slide) {
    final used = {for (final element in slide.elements) element.id};
    var next = 1;
    while (used.contains('e$next')) {
      next++;
    }
    return 'e$next';
  }

  String _short(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = flat.runes.toList();
    return runes.length <= 24
        ? flat
        : '${String.fromCharCodes(runes.take(24))}…';
  }

  /// Notification text in the language the app is showing. A plain unit test
  /// has no binding, so an unresolvable platform locale falls back to English
  /// instead of failing the turn.
  String _backgroundString(String key) {
    final setting = languageSetting;
    final code = setting == 'system' ? _platformLanguage() : setting;
    return Strings(code).t(key);
  }

  String _platformLanguage() {
    try {
      return Strings.resolve([
        WidgetsBinding.instance.platformDispatcher.locale,
      ]);
    } on Object {
      return 'en';
    }
  }

  String _cut(String text) {
    final runes = text.runes.toList();
    return runes.length <= 100
        ? text
        : '${String.fromCharCodes(runes.take(100))}…';
  }

  /// Fetches one public page for the model. The executor owns the address
  /// rules; its codes become a readable result instead of ending the turn.
  Future<String> _fetch(AgentCall call) async {
    final String url;
    try {
      url = _argText(call, 'url');
    } on FormatException {
      return 'Invalid arguments for fetch_url: pass an absolute http(s) URL.';
    }
    try {
      final result = await fetchUrl(url);
      return result.asToolResult();
    } on FormatException catch (error) {
      final code = error.message;
      return switch (code) {
        'fetchScheme' => 'fetch_url needs an absolute http or https URL.',
        'fetchPrivate' =>
          'fetch_url refused: the address is loopback, private or '
              'link-local. Only public http(s) pages can be fetched.',
        'fetchContentType' =>
          'fetch_url refused: the response is not readable text.',
        'fetchTimeout' => 'fetch_url timed out.',
        'fetchProxy' => 'fetch_url cannot run through a proxy.',
        'fetchRedirect' || 'fetchRedirects' =>
          'fetch_url refused: an invalid or endless redirect.',
        _ when code.startsWith('fetchStatus ') =>
          'fetch_url failed: unexpected HTTP ${code.substring(12)}.',
        _ => 'fetch_url failed: $code.',
      };
    } on Object {
      return 'fetch_url failed: the page could not be reached.';
    }
  }

  String _askUser(AgentCall call) {
    try {
      final question = _argText(call, 'question').trim();
      if (question.isEmpty) throw const FormatException('invalidTool');
      final options = _argList(call, 'options');
      _asked = true;
      final choices = options.isEmpty
          ? ''
          : ' Options: ${options.join(' / ')}.';
      return 'Question for the user: $question$choices '
          'The turn ends here; the user\'s next message is the answer.';
    } on FormatException {
      return 'Invalid arguments for ask_user.';
    }
  }

  Deck _deckOf(AgentCall call) {
    final deck = decks[_argText(call, 'deck')];
    if (deck == null) throw const FormatException('invalidTool');
    return deck;
  }

  String _argText(AgentCall call, String key) {
    final value = call.arguments[key];
    if (value is! String) throw const FormatException('invalidTool');
    return value;
  }

  List<String> _argBullets(AgentCall call) => _argList(call, 'bullets');

  List<String> _argList(AgentCall call, String key) {
    final value = call.arguments[key];
    if (value is! List) throw const FormatException('invalidTool');
    return [for (final item in value) if (item is String) item];
  }

  /// Indent levels parallel to the bullets. Missing or short lists mean the
  /// remaining lines sit at the top level.
  List<int> _argLevels(AgentCall call) {
    final value = call.arguments['bullet_levels'];
    if (value == null) return const [];
    if (value is! List) throw const FormatException('invalidTool');
    final levels = <int>[];
    for (final item in value) {
      if (item is! int || item < 0 || item > 2) {
        throw const FormatException('invalidTool');
      }
      levels.add(item);
    }
    return levels;
  }

  int _argIndex(AgentCall call, String key, int length) {
    final value = call.arguments[key];
    if (value is! int || value < 0 || value >= length) {
      throw const FormatException('invalidTool');
    }
    return value;
  }

  double _argNumber(AgentCall call, String key) {
    final value = call.arguments[key];
    if (value is! num || !value.isFinite) {
      throw const FormatException('invalidTool');
    }
    return value.toDouble();
  }

  bool _argBool(AgentCall call, String key) {
    final value = call.arguments[key];
    if (value is! bool) throw const FormatException('invalidTool');
    return value;
  }

  /// An empty string is how a strict tool schema says "no colour": OpenAI
  /// requires every property, so the field cannot simply be omitted.
  String? _argOptional(AgentCall call, String key) {
    final value = _argText(call, key).trim();
    return value.isEmpty ? null : value;
  }

  /// A field added after older callers were written: absent is not an error.
  String? _argOptionalOrNull(AgentCall call, String key) {
    final value = call.arguments[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  double _argNumberOr(AgentCall call, String key, double fallback) {
    final value = call.arguments[key];
    return value is num && value.isFinite ? value.toDouble() : fallback;
  }

  /// Zero means "use the size-based default", which is what a tool call sends
  /// when it does not care about insets.
  double? _optionalPadding(AgentCall call) {
    final value = _argNumber(call, 'padding');
    return value <= 0 ? null : value;
  }

  /// Resolves an `image_id` argument: "last"/"latest" becomes the newest
  /// picture, an empty string stays empty, and an id this app did not produce
  /// is reported so the model can correct the call instead of writing a page
  /// with a broken picture.
  ({String image, String? error}) _imageArg(
    AgentCall call,
    String key,
    List<Asset> created,
  ) {
    final known = <Asset>[...created, ...gallery]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final requested = _argText(call, key).trim();
    if (requested == 'last' || requested == 'latest') {
      if (known.isEmpty) {
        return (
          image: '',
          error:
              'No image exists yet. Call generate_image first, then pass '
              'its id or "last" as image_id.',
        );
      }
      return (image: known.first.id, error: null);
    }
    if (requested.isNotEmpty && !known.any((asset) => asset.id == requested)) {
      return (
        image: '',
        error:
            'Unknown image_id "$requested". Use the id returned by '
            'generate_image, or "last" for the newest image.',
      );
    }
    return (image: requested, error: null);
  }

  /// Runs one tool call and returns the text the model sees as its result.
  ///
  /// An unknown name is answered as an error result instead of thrown: being
  /// told "no such tool" lets the model try something else, which is the whole
  /// point of a multi-step turn.
  Future<String> _runCall(
    StudioApi client,
    AgentCall call,
    List<Asset> refs,
    ImageOptions options,
    List<Asset> created, {
    required void Function(String id, Map<String, dynamic> record) onJob,
  }) async {
    runningTool = call.name;
    notifyListeners();
    try {
      return await _executeCall(
        client,
        call,
        refs,
        options,
        created,
        onJob: onJob,
      );
    } finally {
      runningTool = null;
      notifyListeners();
    }
  }

  /// The Agent's `generate_video`: the submit → poll → download path the video
  /// page uses, with the newest conversation image as the first frame. The
  /// clip is named in the tool result so the model can refer to it, and it
  /// lands on the video page rather than in the transcript.
  Future<String> _generateVideoCall(StudioApi client, AgentCall call) async {
    final parsed = validateVideoCall(call.arguments);
    final options = VideoOptions(
      ratio: parsed.ratio,
      resolution: parsed.resolution,
      seconds: parsed.seconds,
      watermark: parsed.watermark,
      cameraFixed: parsed.cameraFixed,
      seed: parsed.seed,
      style: parsed.style,
    );
    final model = parsed.model.isNotEmpty
        ? parsed.model
        : videoModel.trim().isEmpty
        ? videoModels.first.id
        : videoModel.trim();
    final path = videoPath.trim().isEmpty ? 'videos' : videoPath.trim();
    final refs = agentRefs.take(1).toList();
    final record = <String, dynamic>{
      'kind': 'video',
      'prompt': parsed.prompt,
      'model': model,
      'path': path,
      ...options.toJson(),
      'references': refs.map((asset) => asset.id).toList(),
    };
    final jobId = store.newId();
    await store.job(jobId, 'submitting', record);
    stage = 'working';
    notifyListeners();
    final id = await client.startVideo(
      model,
      videoPrompt(parsed.prompt, options, customStyles),
      refs,
      options,
      path,
      _cancel!,
    );
    await store.job(jobId, 'rendering', {...record, 'task': id});
    var task = VideoTask(id: id, state: 'pending');
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (!task.done && !task.failed) {
      if (DateTime.now().isAfter(deadline)) {
        throw const FormatException('videoTimeout');
      }
      await Future<void>.delayed(const Duration(seconds: 5));
      task = await client.pollVideo(id, path, _cancel!);
    }
    if (task.failed) {
      throw FormatException(
        task.message.isEmpty ? 'videoFailed' : task.message,
      );
    }
    final bytes = await client.downloadVideo(id, path, task.url, _cancel!);
    final asset = await store.saveVideo(
      bytes,
      prompt: parsed.prompt,
      parameters: {...record, 'task': id},
    );
    await store.job(jobId, 'complete', {
      ...record,
      'task': id,
      'asset': asset.id,
    });
    await refresh();
    return jsonEncode({
      'video_id': asset.id,
      'ratio': options.ratio,
      'resolution': options.resolution,
      'seconds': options.seconds,
      'note': 'Saved to the video page; it cannot be shown in the conversation.',
    });
  }

  Future<String> _executeCall(
    StudioApi client,
    AgentCall call,
    List<Asset> refs,
    ImageOptions options,
    List<Asset> created, {
    required void Function(String id, Map<String, dynamic> record) onJob,
  }) async {
    switch (call.name) {
      case 'create_deck':
        return _createDeck(call);
      case 'add_slide':
        return _addSlide(call, created);
      case 'add_text':
        return _addText(call);
      case 'update_text':
        return _updateText(call);
      case 'add_image':
        return _addImage(call, created);
      case 'add_table':
        return _addTable(call);
      case 'add_chart':
        return _addChart(call);
      case 'set_background':
        return _setBackground(call, created);
      case 'update_slide':
        return _updateSlide(call);
      case 'move_slide':
        return _moveSlide(call);
      case 'set_notes':
        return _setNotes(call);
      case 'remove_element':
        return _removeElement(call);
      case 'remove_slide':
        return _removeSlide(call);
      case 'finish_deck':
        return _finishDeck(call);
      case 'fetch_url':
        return _fetch(call);
      case 'ask_user':
        return _askUser(call);
      case 'generate_video':
        return _generateVideoCall(client, call);
    }
    if (call.name != imageTool['name']) {
      return 'Unknown tool "${call.name}": this build has no such tool.';
    }
    final parsed = validateToolCall(call.arguments);
    final jobOptions = options.copyWith(
      size: parsed.aspectRatio == null ? null : sizePresets[parsed.aspectRatio]!,
      quality: parsed.quality,
      style: parsed.style,
    );
    stage = 'working';
    notifyListeners();
    final id = store.newId();
    final record = <String, dynamic>{
      'prompt': parsed.prompt,
      'references': refs.map((asset) => asset.id).toList(),
      'model': client.config.imageModel,
      ...jobOptions.toJson(),
      'createdAt': DateTime.now().toIso8601String(),
      'session': session,
    };
    await _recordJob(id, 'submitting', record);
    onJob(id, record);
    jobs = await store.jobs();
    notifyListeners();
    try {
      final assets = await _runJob(
        client,
        id,
        record,
        parsed.prompt,
        refs,
        jobOptions,
      );
      created.addAll(assets);
      if (assets.isEmpty) return 'The image service returned no image.';
      final ids = assets.map((asset) => asset.id).join(', ');
      return 'Generated ${assets.length} image(s). image_id: $ids. '
          'Pass this exact id as add_slide.image_id, or "last" for the newest.';
    } catch (e) {
      if (errorCode(e) == 'cancelled') rethrow;
      // A failed image is a tool result, not the end of the turn: the text
      // model gets the code and decides whether to retry, change the prompt,
      // or ask the user. Only a failing text-model request ends the turn.
      final code = errorCode(e);
      final detail = errorDetailOf(e, secrets: [key, imageKey]);
      final uncertain =
          code == 'unknown' ||
          code == 'cancelled' ||
          code == 'incompleteImageStream';
      await _recordJob(id, uncertain ? 'unknown' : 'failed', {
        ...record,
        'error': code,
        'detail': detail,
        if (e is ImageApiException && e.outputs.isNotEmpty)
          'outputs': e.outputs,
      });
      jobs = await store.jobs();
      notifyListeners();
      return 'Image generation failed ($code)'
          '${detail == null ? '' : ': $detail'}. '
          'You may retry with a different prompt or aspect ratio, or ask the '
          'user what to do with ask_user.';
    }
  }

  /// Runs one recorded generation and files whatever it returns. A fresh
  /// submission and a retry both finish their job through here, so the two
  /// cannot drift apart in what they store.
  Future<List<Asset>> _runJob(
    StudioApi client,
    String jobId,
    Map<String, dynamic> record,
    String prompt,
    List<Asset> refs,
    ImageOptions options,
  ) async {
    final images = await client.generate(
      // The style words belong to this request only; the asset keeps the prompt
      // the user actually wrote.
      withStyle(prompt, styleFor(options.style)),
      refs,
      options,
      _cancel!,
    );
    final created = <Asset>[];
    for (final bytes in images) {
      // What gets recorded is the size measured from the bytes, not the one that
      // was asked for: a request for a wide size can come back square, and the
      // Gallery needs the measured one to show that at all.
      final actual = imageSizeOf(bytes);
      created.add(
        await store.saveAsset(
          bytes,
          prompt: prompt,
          parentId: refs.isEmpty ? null : refs.first.id,
          parameters: actual == null ? record : {...record, 'actualSize': actual},
        ),
      );
    }
    await _recordJob(jobId, 'complete', {
      ...record,
      'assets': created.map((a) => a.id).toList(),
    });
    return created;
  }

  /// Files the images a job produced into the conversation that asked for them.
  Future<void> _attachResults(
    Map<String, dynamic> record,
    List<Asset> created,
    bool vision,
  ) async {
    final targetSession = record['session'] as String?;
    if (targetSession == null || created.isEmpty) return;
    await store.addMessage(
      targetSession,
      ChatEntry('assistant', '', assetIds: created.map((a) => a.id).toList()),
    );
    if (targetSession == session && vision) agentRefs = [created.first];
  }

  /// Picks an unfinished job back up from the record it left behind.
  ///
  /// A job the service answered but whose images were never downloaded only
  /// needs the download repeated; one that never got an answer is submitted
  /// again from its own prompt and references. This is what lets a turn survive
  /// the phone killing the app in the background: the record is written before
  /// the request goes out, so the work can be resumed instead of vanishing with
  /// the process.
  Future<void> retryJob(ImageJob job) async {
    if (busy) return;
    final outputs = List<String>.from(job.record['outputs'] as List? ?? []);
    if (outputs.isNotEmpty) return retryDownload(job);
    final prompt = job.prompt;
    if (prompt.trim().isEmpty) return;
    final options = job.options;
    final refs = <Asset>[];
    for (final id in List<String>.from(
      job.record['references'] as List? ?? [],
    )) {
      final asset = await store.asset(id);
      if (asset != null) refs.add(asset);
    }
    // The record names the model this job was submitted to. The model may have
    // been switched since, and a retry that silently ran on the current one
    // would file the result under a model that never produced it.
    final recorded = job.record['model'] as String?;
    final client = StudioApi(
      recorded == null || recorded.isEmpty
          ? activeConfig
          : activeConfig.copyWith(imageModel: recorded),
      key,
      imageKey,
      store,
      videoKey: videoKey,
    );
    busy = true;
    error = null;
    errorDetail = null;
    stage = 'working';
    _cancel = CancelToken();
    _api = client;
    notifyListeners();
    try {
      client.validateGeneration(prompt, refs, options);
      await _recordJob(job.id, 'submitting', job.record);
      jobs = await store.jobs();
      notifyListeners();
      final created = await _runJob(
        client,
        job.id,
        job.record,
        prompt,
        refs,
        options,
      );
      await _attachResults(job.record, created, client.config.vision);
      await refresh();
    } catch (e) {
      error = errorCode(e, submitted: true);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      await _recordJob(job.id, 'failed', {
        ...job.record,
        'error': error,
        'detail': errorDetail,
        if (e is ImageApiException && e.outputs.isNotEmpty)
          'outputs': e.outputs,
      });
      jobs = await store.jobs();
    } finally {
      client.close();
      _api = null;
      _cancel = null;
      busy = false;
      notifyListeners();
    }
  }

  /// Removes a conversation and the settings that belong to it. The images it
  /// produced stay in the Gallery: they are the user's work, not chat state.
  Future<void> deleteConversation(String id) async {
    if (busy) return;
    // Unfinished work outlives the conversation: the images a job may still
    // produce are the user's, but a job that kept naming the deleted session
    // would bring it back as a conversation holding one image.
    for (final job in await store.jobs()) {
      if (job.record['session'] != id) continue;
      await _recordJob(job.id, job.state, {...job.record, 'session': null});
    }
    await store.deleteSession(id);
    for (final deck in await store.decks(id)) {
      await store.deleteDeck(deck.id);
    }
    if (id == session) {
      session = store.newId();
      await store.setSetting('currentSession', session);
      _conversationSettings = {};
      chat = [];
      agentRefs = [];
      decks.clear();
      activeDeck = null;
      _resetCompaction();
    }
    await refresh();
  }

  void cancel() {
    _cancel?.cancel();
  }

  Future<void> export(Asset asset) async {
    final bytes = await store.file(asset).readAsBytes();
    if (Platform.isAndroid) {
      await const MethodChannel(
        'app.imagyn/media',
      ).invokeMethod<String>('saveImage', {
        'bytes': bytes,
        'name': 'Imagyn-${asset.id}${p.extension(asset.path)}',
        'mime': asset.mime,
      });
    } else {
      final target = await getSaveLocation(
        suggestedName: 'Imagyn-${asset.id}${p.extension(asset.path)}',
      );
      if (target != null) {
        await XFile.fromData(bytes, mimeType: asset.mime).saveTo(target.path);
      }
    }
  }

  /// Builds the `.pptx` bytes from a snapshot of the deck, so an Agent that is
  /// still adding slides cannot change the list while the pictures are read.
  Future<Uint8List> _renderDeck(Deck deck) async {
    final slides = List<Slide>.of(deck.slides);
    final images = <String, PptxImage>{};
    for (final slide in slides) {
      final ids = <String>{
        if (slide.imageId != null) slide.imageId!,
        if (deck.backgroundFor(slide) != null) deck.backgroundFor(slide)!,
        for (final element in slide.elements)
          if (element.imageId != null) element.imageId!,
      };
      for (final id in ids) {
        if (images.containsKey(id)) continue;
        final asset = await store.asset(id);
        if (asset == null) continue;
        final bytes = await store.file(asset).readAsBytes();
        final size = imageSizeOf(bytes)?.split('x') ?? const <String>[];
        images[id] = PptxImage(
          bytes: bytes,
          mime: asset.mime,
          width: size.isEmpty ? 16 : int.tryParse(size.first) ?? 16,
          height: size.length < 2 ? 9 : int.tryParse(size.last) ?? 9,
        );
      }
    }
    return buildPptx(
      Deck(
        id: deck.id,
        title: deck.title,
        aspectRatio: deck.aspectRatio,
        finished: deck.finished,
        backgroundImageId: deck.backgroundImageId,
        slides: slides,
      ),
      images,
    );
  }

  File _privateDeck(Deck deck) =>
      File(p.join(store.root.path, 'decks', '${_deckFileName(deck.title)}.pptx'));

  Future<void> _writePrivate(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.partial');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(target.path);
  }

  /// Keeps a finished deck in the app's private directory, so it can be opened
  /// or exported after the process is restarted even if the user never tapped
  /// Export. Failures are silent: the deck JSON is the authority and the export
  /// path builds a fresh file anyway.
  Future<void> _snapshotDeck(Deck deck) async {
    try {
      final bytes = await _renderDeck(deck);
      await _writePrivate(_privateDeck(deck), bytes);
    } catch (_) {
      // The JSON copy and a later export rebuild this file; a missing snapshot
      // must not fail the turn that finished the deck.
    }
  }

  /// Exports the deck as a real `.pptx`, not a picture of the slides: each
  /// page becomes a text frame and, when it has one, an embedded picture, so
  /// PowerPoint or WPS can keep editing it.
  ///
  /// The file is written in the app's private directory first and then copied
  /// to the public folder. If the public write fails, the private copy stays
  /// and the next export can retry without rebuilding.
  Future<void> exportDeck(Deck deck) async {
    final bytes = await _renderDeck(deck);
    final name = '${_deckFileName(deck.title)}.pptx';
    final staged = _privateDeck(deck);
    await _writePrivate(staged, bytes);
    const mime =
        'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    if (Platform.isAndroid) {
      await const MethodChannel(
        'app.imagyn/media',
      ).invokeMethod<String>('saveFile', {
        'bytes': bytes,
        'name': name,
        'mime': mime,
      });
    } else {
      final target = await getSaveLocation(suggestedName: name);
      // Cancelling keeps the private copy for a later attempt.
      if (target == null) return;
      await XFile.fromData(bytes, mimeType: mime).saveTo(target.path);
    }
    // The public copy is now the user's file; the staging copy is deleted so
    // the deck is not quietly duplicated. A failed delete must not turn a
    // successful export into an error.
    try {
      await staged.delete();
    } on FileSystemException {
      // Leftover private file is harmless.
    }
  }

  /// Opens the system share sheet for one picture. The sheet is also the
  /// "open with" path: every app that can read the type is offered there.
  Future<void> shareAsset(Asset asset) async {
    final prompt = asset.prompt.trim();
    await shareFile(store.file(asset).path, prompt.isEmpty ? null : prompt);
  }

  /// Builds the deck once and hands the `.pptx` to the share sheet, so it can
  /// be sent on or opened in PowerPoint/WPS without going through Export.
  Future<void> shareDeck(Deck deck) async {
    final bytes = await _renderDeck(deck);
    final directory = Directory(p.join(store.root.path, 'shared'));
    await directory.create(recursive: true);
    final file = File(
      p.join(directory.path, '${_deckFileName(deck.title)}.pptx'),
    );
    await file.writeAsBytes(bytes, flush: true);
    final title = deck.title.trim();
    await shareFile(file.path, title.isEmpty ? null : title);
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _api?.close();
    super.dispose();
  }
}

/// A filename every platform accepts. Windows rejects `\ / : * ? " < > |`
/// and control characters, and a deck title may contain any of them.
String _deckFileName(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'Imagyn deck';
  return cleaned.length <= 80 ? cleaned : cleaned.substring(0, 80).trim();
}

String errorCode(Object error, {bool submitted = false}) {
  if (error is ImageApiException) return error.code;
  if (error is FormatException) return error.message;
  if (error is DioException) {
    if (CancelToken.isCancel(error)) return 'cancelled';
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) return 'authError';
    if (status == 429) return 'rateLimit';
    // Requests carrying the key never follow a redirect, so a 3xx reaching this
    // point means the endpoint tried to hand the request to another address.
    if (status != null && status >= 300 && status < 400) {
      return 'redirectBlocked';
    }
    if (status != null && status >= 400 && status < 500) return 'serviceError';
    if (submitted) return 'unknown';
  }
  return submitted ? 'unknown' : 'error';
}

/// The server's own words about a failure: the HTTP status and the start of the
/// response body. Kept separate from [errorCode] because it is diagnostic text,
/// not a localizable message — without it every 4xx reads the same and nobody
/// can tell a bad key from a wrong path from a proxy block.
///
/// [secrets] are the API keys in play. They are stripped before the text is
/// returned: a gateway or a compatible service may echo the request (including
/// its `Authorization` header) back inside an error body, and this text is
/// rendered in the UI.
String? errorDetailOf(Object failure, {List<String> secrets = const []}) {
  if (failure is ImageApiException) {
    final detail = redact(failure.detail, secrets);
    return detail.length > 500 ? '${detail.substring(0, 500)}…' : detail;
  }
  if (failure is DioException) {
    final response = failure.response;
    final status = response?.statusCode;
    var text = redact(response?.data?.toString().trim() ?? '', secrets);
    if (text.length > 300) text = '${text.substring(0, 300)}…';
    final parts = <String>[
      if (status != null) 'HTTP $status',
      if (text.isNotEmpty) text,
      if (status == null && text.isEmpty) failure.message ?? '',
    ];
    return redact(parts.where((part) => part.isNotEmpty).join(' · '), secrets);
  }
  if (failure is FormatException) return failure.message;
  return redact(failure.toString(), secrets);
}

/// Removes anything credential-shaped from diagnostic text: the configured keys
/// themselves, plus the usual auth fields a gateway may echo back.
String redact(String text, List<String> secrets) {
  var result = text;
  for (final secret in secrets) {
    final trimmed = secret.trim();
    if (trimmed.length >= 4) result = result.replaceAll(trimmed, '[REDACTED]');
  }
  // Dart's RegExp is ECMAScript syntax, which has no inline `(?i)` flag — an
  // invalid pattern throws at construction, so the case-insensitivity has to be
  // passed as an argument. (The analyzer's valid_regexps lint is what caught
  // this: a Python port of the same pattern proves nothing, because Python does
  // accept `(?i)`.)
  result = result.replaceAllMapped(
    RegExp(
      r'(authorization|api[_-]?key|x-api-key)("?\s*[:=]\s*"?)[^\s",}]+',
      caseSensitive: false,
    ),
    (match) => '${match[1]}${match[2]}[REDACTED]',
  );
  return result.replaceAll(
    RegExp(r'bearer\s+[A-Za-z0-9._\-]{8,}', caseSensitive: false),
    'Bearer [REDACTED]',
  );
}
