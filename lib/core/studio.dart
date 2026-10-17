import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../l10n/strings.dart';
import 'api.dart';
import 'models.dart';
import 'store.dart';

class Studio extends ChangeNotifier {
  Studio(this.store);
  final LocalStore store;
  ServiceConfig config = const ServiceConfig();
  String key = '', imageKey = '', session = '', theme = 'system';

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
  List<Asset> gallery = [], galleryRefs = [], agentRefs = [];
  List<ChatEntry> chat = [];
  List<ImageJob> jobs = [];
  Set<String> favorites = {};
  ImageOptions imageOptions = const ImageOptions();
  CancelToken? _cancel;
  StudioApi? _api;
  Map<String, dynamic> _conversationSettings = {};
  Future<void> _favoriteUpdates = Future<void>.value();

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
    await _loadConversationSettings();
    await refresh();
    await _restoreAgentReferences();
    ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    gallery = (await store.assets()).where((a) => a.prompt.isNotEmpty).toList();
    chat = await store.messages(session);
    jobs = await store.jobs();
    notifyListeners();
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
    String locale,
    String appearance,
    bool motion,
  ) async {
    if (busy) return;
    if (value.baseUrl.isNotEmpty) value.endpoint('models');
    if (value.imageBaseUrl.isNotEmpty) value.imageEndpoint('models');
    for (final options in value.agentProfiles.values) {
      options.validate(value.protocol);
    }
    final probe = networkClient(value.proxy);
    probe.close();
    final language = locale == 'system' || Strings.isSupported(locale)
        ? locale
        : 'system';
    await store.saveConfig(value, apiKey.trim(), pictureKey.trim());
    await store.setSetting('language', language);
    await store.setSetting('theme', appearance);
    await store.setSetting('reduceMotion', motion.toString());
    config = value;
    key = apiKey.trim();
    imageKey = pictureKey.trim();
    languageSetting = language;
    theme = appearance;
    reduceMotion = motion;
    onboarding = false;
    notifyListeners();
  }

  StudioApi get api => StudioApi(activeConfig, key, imageKey, store);

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
    notifyListeners();
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
    await store.setSetting('imageOptions', jsonEncode(value.toJson()));
    imageOptions = value;
    notifyListeners();
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

  Future<void> dismissJob(ImageJob job) async {
    await store.dismissJob(job.id);
    await refresh();
  }

  Future<void> submit(
    String prompt,
    bool agent,
    ImageOptions options, {
    VoidCallback? onAccepted,
  }) async {
    if (busy) return;
    if (prompt.trim().isEmpty) throw const FormatException('emptyPrompt');
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
    stage = agent ? 'discussing' : 'working';
    _cancel = CancelToken();
    _api = client;
    String? jobId;
    Map<String, dynamic>? record;
    final created = <Asset>[];
    notifyListeners();
    try {
      String? imagePrompt = prompt.trim();
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
            prompt.trim(),
            assetIds: refs.map((a) => a.id).toList(),
          ),
        );
        onAccepted?.call();
        chat = await store.messages(session);
        notifyListeners();
        // One turn is not one request: the model may call a tool, read the
        // result and decide to call another. The cap keeps a loop that never
        // settles from spending the whole session; the last text stands as the
        // answer when it is reached.
        const maxSteps = 8;
        for (var step = 0; step < maxSteps; step++) {
          final result = requestConfig.streamAgent
              ? await client.converseStream(
                  chat,
                  refs,
                  _cancel!,
                  options: requestAgentOptions,
                  onDelta: _stream,
                )
              : await client.converse(
                  chat,
                  refs,
                  _cancel!,
                  options: requestAgentOptions,
                );
          reply = result.text;
          reasoning = result.reasoning;
          if (result.calls.isEmpty) break;
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
          for (final call in result.calls) {
            final output = await _runCall(
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
            await store.addMessage(
              session,
              ChatEntry('tool', output, callId: call.id, name: call.name),
            );
            chat = await store.messages(session);
          }
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
        await store.job(candidateJobId, 'submitting', row);
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
        if (created.isNotEmpty && requestConfig.vision) {
          agentRefs = [created.first];
        }
      }
      await refresh();
    } catch (e) {
      error = errorCode(e, submitted: jobId != null);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      final failedJob = jobId;
      if (failedJob != null) {
        final uncertain =
            error == 'unknown' ||
            error == 'cancelled' ||
            error == 'incompleteImageStream';
        await store.job(failedJob, uncertain ? 'unknown' : 'failed', {
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
      _clearStream();
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
      await store.job(job.id, 'complete', {
        ...parameters,
        'assets': created.map((a) => a.id).toList(),
      });
      await _attachResults(job.record, created, client.config.vision);
      await refresh();
    } catch (e) {
      error = errorCode(e);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      await store.job(job.id, 'failed', {
        ...job.record,
        'error': error,
        'detail': errorDetail,
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
      notifyListeners();
      return 'Deck "$title" created with id $id ($ratio).';
    } on FormatException {
      return 'Invalid arguments for create_deck.';
    }
  }

  String _addSlide(AgentCall call) {
    try {
      final deck = _deckOf(call);
      final image = _argText(call, 'image_id');
      deck.slides.add(
        Slide(
          title: _argText(call, 'title'),
          bullets: _argBullets(call),
          imageId: image.isEmpty ? null : image,
        ),
      );
      notifyListeners();
      return 'Slide ${deck.slides.length} added to deck ${deck.id}.';
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
        imageId: previous.imageId,
      );
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
      notifyListeners();
      return 'Slide ${index + 1} removed. ${deck.slides.length} remain.';
    } on FormatException {
      return 'Invalid arguments for remove_slide.';
    }
  }

  String _finishDeck(AgentCall call) {
    try {
      final deck = _deckOf(call);
      return 'Deck ${deck.id} finished: ${deck.slides.length} slides.';
    } on FormatException {
      return 'Invalid arguments for finish_deck.';
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

  List<String> _argBullets(AgentCall call) {
    final value = call.arguments['bullets'];
    if (value is! List) throw const FormatException('invalidTool');
    return [for (final item in value) if (item is String) item];
  }

  int _argIndex(AgentCall call, String key, int length) {
    final value = call.arguments[key];
    if (value is! int || value < 0 || value >= length) {
      throw const FormatException('invalidTool');
    }
    return value;
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
    switch (call.name) {
      case 'create_deck':
        return _createDeck(call);
      case 'add_slide':
        return _addSlide(call);
      case 'update_slide':
        return _updateSlide(call);
      case 'remove_slide':
        return _removeSlide(call);
      case 'finish_deck':
        return _finishDeck(call);
    }
    if (call.name != imageTool['name']) {
      return 'Unknown tool "${call.name}": this build has no such tool.';
    }
    final parsed = validateToolCall(call.arguments);
    final jobOptions = parsed.aspectRatio == null
        ? options
        : options.copyWith(size: sizePresets[parsed.aspectRatio]!);
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
    await store.job(id, 'submitting', record);
    onJob(id, record);
    jobs = await store.jobs();
    notifyListeners();
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
    return 'Generated ${assets.length} image(s): '
        '${assets.map((asset) => asset.id).join(', ')}.';
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
    final images = await client.generate(prompt, refs, options, _cancel!);
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
    await store.job(jobId, 'complete', {
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
      await store.job(job.id, 'submitting', job.record);
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
      await store.job(job.id, 'failed', {
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
      await store.job(job.id, job.state, {...job.record, 'session': null});
    }
    await store.deleteSession(id);
    if (id == session) {
      session = store.newId();
      await store.setSetting('currentSession', session);
      _conversationSettings = {};
      chat = [];
      agentRefs = [];
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

  @override
  void dispose() {
    _cancel?.cancel();
    _api?.close();
    super.dispose();
  }
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
