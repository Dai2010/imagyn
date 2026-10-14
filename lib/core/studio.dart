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
  CancelToken? _cancel;
  StudioApi? _api;

  Future<void> initialize() async {
    config = await store.config();
    key = await store.apiKey();
    imageKey = await store.imageKey();
    final storedLanguage = await store.setting('language') ?? 'system';
    languageSetting = storedLanguage == 'system' || Strings.isSupported(storedLanguage)
        ? storedLanguage : 'system';
    theme = await store.setting('theme') ?? 'system';
    reduceMotion = await store.setting('reduceMotion') == 'true';
    onboarding = await store.setting('onboardingVersion') == null;
    session = await store.setting('currentSession') ?? store.newId();
    // A job that was mid-submission when the process died may still be running
    // on the service. Say so at startup, before another paid request is sent.
    if (await store.recoverJobs() > 0) error = 'unknown';
    await refresh();
    ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    gallery = (await store.assets()).where((a) => a.prompt.isNotEmpty).toList();
    chat = await store.messages(session);
    notifyListeners();
  }

  Future<void> skipOnboarding() async {
    await store.setSetting('onboardingVersion', '1');
    onboarding = false;
    notifyListeners();
  }

  Future<void> saveSettings(ServiceConfig value, String apiKey, String pictureKey,
      String locale, String appearance, bool motion) async {
    if (busy) return;
    if (value.baseUrl.isNotEmpty) value.endpoint('models');
    if (value.imageBaseUrl.isNotEmpty) value.imageEndpoint('models');
    final probe = networkClient(value.proxy);
    probe.close();
    final language = locale == 'system' || Strings.isSupported(locale) ? locale : 'system';
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

  StudioApi get api => StudioApi(config, key, imageKey, store);

  Future<void> pickReferences(bool agent) async {
    if (busy) return;
    final selected = await openFiles(acceptedTypeGroups: [
      const XTypeGroup(label: 'Images', extensions: ['png','jpg','jpeg','webp'],
        mimeTypes: ['image/png','image/jpeg','image/webp'])]);
    final refs = agent ? agentRefs : galleryRefs;
    if (refs.length + selected.length > config.maxReferences) {
      throw const FormatException('referenceLimit');
    }
    // Read and check every file before writing any of them: a file that turns
    // out to be too large or not an image must not leave the earlier ones
    // behind as assets nothing in the UI can reach.
    final payloads = <Uint8List>[];
    for (final file in selected) {
      if (await file.length() > StudioApi.maxImageBytes) throw const FormatException('imageTooLarge');
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
    if (agent) { agentRefs = [asset]; } else { galleryRefs = [asset]; }
    notifyListeners();
  }

  Future<void> newConversation() async {
    if (busy) return;
    session = store.newId();
    await store.setSetting('currentSession', session);
    chat = [];
    agentRefs = [];
    notifyListeners();
  }

  Future<List<Map<String, Object?>>> conversations() => store.db.rawQuery(
    'SELECT session, MIN(id) AS first_id FROM messages GROUP BY session ORDER BY first_id DESC');

  Future<void> switchConversation(String id) async {
    if (busy) return;
    session = id;
    await store.setSetting('currentSession', id);
    chat = await store.messages(session);
    agentRefs = [];
    for (final entry in chat.reversed) {
      if (entry.role == 'assistant' && entry.assetIds.isNotEmpty) {
        final asset = await store.asset(entry.assetIds.first);
        if (asset != null) agentRefs = [asset];
        break;
      }
    }
    notifyListeners();
  }

  Future<void> submit(String prompt, bool agent, String size) async {
    if (busy) return;
    if (prompt.trim().isEmpty) throw const FormatException('emptyPrompt');
    final refs = List<Asset>.of(agent ? agentRefs : galleryRefs);
    final client = api;
    busy = true;
    error = null;
    errorDetail = null;
    stage = agent ? 'discussing' : 'working';
    _cancel = CancelToken();
    _api = client;
    String? jobId;
    notifyListeners();
    try {
      String? imagePrompt = prompt.trim();
      String reply = '';
      if (agent) {
        await store.addMessage(session, ChatEntry('user', prompt.trim(), assetIds: refs.map((a) => a.id).toList()));
        chat = await store.messages(session);
        notifyListeners();
        final result = await client.converse(chat, refs, _cancel!);
        reply = result.text;
        imagePrompt = result.imagePrompt;
      }
      final created = <Asset>[];
      if (imagePrompt != null) {
        stage = 'working';
        notifyListeners();
        jobId = store.newId();
        final record = {'prompt': imagePrompt, 'references': refs.map((a) => a.id).toList(),
          'model': config.imageModel, 'size': size, 'session': agent ? session : null};
        await store.job(jobId, 'submitting', record);
        final images = await client.generate(imagePrompt, refs, size, _cancel!);
        for (final bytes in images) {
          created.add(await store.saveAsset(bytes, prompt: imagePrompt,
            parentId: refs.isEmpty ? null : refs.first.id));
        }
        await store.job(jobId, 'complete', {...record, 'assets': created.map((a) => a.id).toList()});
      }
      if (agent) {
        await store.addMessage(session, ChatEntry('assistant',
          reply.isEmpty && created.isNotEmpty ? '' : reply,
          assetIds: created.map((a) => a.id).toList()));
        if (created.isNotEmpty) agentRefs = [created.first];
      }
      await refresh();
    } catch (e) {
      error = errorCode(e, submitted: jobId != null);
      errorDetail = errorDetailOf(e, secrets: [key, imageKey]);
      if (jobId != null) await store.job(jobId, 'unknown', {'prompt': prompt, 'session': session});
    } finally {
      client.close();
      _api = null;
      _cancel = null;
      busy = false;
      notifyListeners();
    }
  }

  void cancel() { _cancel?.cancel(); }

  Future<void> export(Asset asset) async {
    final bytes = await store.file(asset).readAsBytes();
    if (Platform.isAndroid) {
      await const MethodChannel('app.imagyn/media').invokeMethod<String>('saveImage', {
        'bytes': bytes, 'name': 'Imagyn-${asset.id}${p.extension(asset.path)}', 'mime': asset.mime,
      });
    } else {
      final target = await getSaveLocation(suggestedName: 'Imagyn-${asset.id}${p.extension(asset.path)}');
      if (target != null) await XFile.fromData(bytes, mimeType: asset.mime).saveTo(target.path);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _api?.close();
    super.dispose();
  }
}

String errorCode(Object error, {bool submitted = false}) {  if (error is FormatException) return error.message;
  if (error is DioException) {
    if (CancelToken.isCancel(error)) return 'cancelled';
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) return 'authError';
    if (status == 429) return 'rateLimit';
    // Requests carrying the key never follow a redirect, so a 3xx reaching this
    // point means the endpoint tried to hand the request to another address.
    if (status != null && status >= 300 && status < 400) return 'redirectBlocked';
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
  if (failure is DioException) {
    final response = failure.response;
    final status = response?.statusCode;
    var text = response?.data?.toString().trim() ?? '';
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
  result = result.replaceAllMapped(
    RegExp(r'(?i)(authorization|api[_-]?key|x-api-key)("?\s*[:=]\s*"?)[^\s",}]+'),
    (match) => '${match[1]}${match[2]}[REDACTED]');
  return result.replaceAll(RegExp(r'(?i)bearer\s+[A-Za-z0-9._\-]{8,}'), 'Bearer [REDACTED]');
}
