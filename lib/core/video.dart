/// Video generation: the parameters a Seedance-style service expects, the
/// models worth offering out of the box, and a tolerant reader for the task
/// objects that come back while a clip renders.
library;

import 'styles.dart';

/// One video model. Gateways spell the ids differently, so this is a starting
/// list rather than a closed set: the settings field accepts any id.
class VideoModel {
  const VideoModel(this.id, this.label);
  final String id;
  final String label;
}

const videoModels = [
  VideoModel('seedance-1-0-pro-250528', 'Seedance 1.0 Pro'),
  VideoModel('seedance-1-0-lite-t2v-250428', 'Seedance 1.0 Lite'),
  VideoModel('sora-2', 'Sora 2'),
  VideoModel('veo-3-1', 'Veo 3.1'),
  VideoModel('kling-v2-5', 'Kling 2.5'),
  VideoModel('wan2-5-t2v', 'Wan 2.5'),
  VideoModel('hailuo-02', 'Hailuo 02'),
];

/// What a clip is asked for. [style] is only an id: the words travel inside the
/// prompt, the same way they do for images.
class VideoOptions {
  const VideoOptions({
    this.ratio = '16:9',
    this.resolution = '720p',
    this.seconds = 5,
    this.watermark = false,
    this.cameraFixed = false,
    this.seed = -1,
    this.style = '',
  });

  static const ratios = ['16:9', '9:16', '1:1', '4:3', '3:4', '21:9', 'adaptive'];
  static const resolutions = ['480p', '720p', '1080p'];
  static const minSeconds = 3;
  static const maxSeconds = 12;

  final String ratio;
  final String resolution;
  final int seconds;
  final bool watermark;
  final bool cameraFixed;

  /// -1 lets the service pick, which is what a re-run usually wants.
  final int seed;
  final String style;

  VideoOptions copyWith({
    String? ratio,
    String? resolution,
    int? seconds,
    bool? watermark,
    bool? cameraFixed,
    int? seed,
    String? style,
  }) => VideoOptions(
    ratio: ratio ?? this.ratio,
    resolution: resolution ?? this.resolution,
    seconds: seconds ?? this.seconds,
    watermark: watermark ?? this.watermark,
    cameraFixed: cameraFixed ?? this.cameraFixed,
    seed: seed ?? this.seed,
    style: style ?? this.style,
  );

  void validate() {
    if (!ratios.contains(ratio) ||
        !resolutions.contains(resolution) ||
        seconds < minSeconds ||
        seconds > maxSeconds ||
        seed < -1 ||
        seed > 0xFFFFFFFF) {
      throw const FormatException('invalidVideoOptions');
    }
  }

  Map<String, dynamic> toJson() => {
    'ratio': ratio,
    'resolution': resolution,
    'seconds': seconds,
    'watermark': watermark,
    'cameraFixed': cameraFixed,
    'seed': seed,
    if (style.isNotEmpty) 'style': style,
  };

  factory VideoOptions.fromJson(Map<String, dynamic> value) => VideoOptions(
    ratio: value['ratio'] as String? ?? '16:9',
    resolution: value['resolution'] as String? ?? '720p',
    seconds: (value['seconds'] as num? ?? 5).toInt(),
    watermark: value['watermark'] == true,
    cameraFixed: value['cameraFixed'] == true,
    seed: (value['seed'] as num? ?? -1).toInt(),
    style: value['style'] as String? ?? '',
  );

  /// The shape a Seedance-compatible endpoint reads. The OpenAI video endpoint
  /// wants a `size` instead, so [size] is sent alongside rather than instead.
  Map<String, dynamic> requestFields() {
    validate();
    return {
      'ratio': ratio,
      'resolution': resolution,
      'duration': seconds,
      'seed': seed,
      'watermark': watermark,
      'camera_fixed': cameraFixed,
    };
  }

  /// `1280x720`-style size for the OpenAI video endpoint. Empty for `adaptive`,
  /// which means "whatever suits the content".
  String get size => switch (ratio) {
    '16:9' => switch (resolution) {
      '480p' => '854x480',
      '1080p' => '1920x1080',
      _ => '1280x720',
    },
    '9:16' => switch (resolution) {
      '480p' => '480x854',
      '1080p' => '1080x1920',
      _ => '720x1280',
    },
    '1:1' => switch (resolution) {
      '480p' => '480x480',
      '1080p' => '1080x1080',
      _ => '720x720',
    },
    '4:3' => switch (resolution) {
      '480p' => '640x480',
      '1080p' => '1440x1080',
      _ => '960x720',
    },
    '3:4' => switch (resolution) {
      '480p' => '480x640',
      '1080p' => '1080x1440',
      _ => '720x960',
    },
    '21:9' => switch (resolution) {
      '480p' => '1120x480',
      '1080p' => '2520x1080',
      _ => '1680x720',
    },
    _ => '',
  };
}

/// A task as the service reports it, normalised to four states so the poller
/// does not have to know every gateway's vocabulary.
class VideoTask {
  const VideoTask({
    required this.id,
    required this.state,
    this.url = '',
    this.message = '',
  });
  final String id;

  /// `pending`, `running`, `done` or `failed`.
  final String state;
  final String url;
  final String message;

  bool get done => state == 'done';
  bool get failed => state == 'failed';
}

/// Reads a task object from either the OpenAI shape (`id`, `status`) or the
/// task-id shape gateways use (`task_id`, `status`, `url`).
VideoTask parseVideoTask(Map<String, dynamic> json) {
  String text(List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  final id = text(['id', 'task_id', 'taskId', 'video_id', 'videoId']);
  final raw = text(['status', 'state', 'task_status', 'taskStatus']);
  final state = switch (raw.toLowerCase()) {
    'queued' || 'pending' || 'submitted' || 'waiting' => 'pending',
    'running' ||
    'in_progress' ||
    'in-progress' ||
    'processing' ||
    'generating' => 'running',
    'completed' || 'succeeded' || 'success' || 'done' || 'finished' => 'done',
    'failed' || 'error' || 'cancelled' || 'canceled' || 'expired' => 'failed',
    _ => 'pending',
  };
  return VideoTask(
    id: id,
    state: state,
    url: videoUrlOf(json),
    message: videoMessageOf(json),
  );
}

/// The first usable video address in a task object, wherever the gateway put
/// it: a plain field, or the first element of `data` / `output`.
String videoUrlOf(Map<String, dynamic> json) {
  const keys = ['url', 'video_url', 'videoUrl', 'output_url', 'outputUrl'];
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
  }
  for (final key in ['data', 'output', 'results', 'videos']) {
    final list = json[key];
    if (list is List && list.isNotEmpty) {
      final first = list.first;
      if (first is String && first.isNotEmpty) return first;
      if (first is Map) return videoUrlOf(Map<String, dynamic>.from(first));
    }
  }
  for (final key in ['content', 'result', 'video']) {
    final nested = json[key];
    if (nested is Map) {
      final found = videoUrlOf(Map<String, dynamic>.from(nested));
      if (found.isNotEmpty) return found;
    }
  }
  return '';
}

/// The service's own words about a failed task, when it sent any.
String videoMessageOf(Map<String, dynamic> json) {
  for (final key in ['fail_reason', 'error_message', 'message', 'detail']) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  final error = json['error'];
  if (error is String && error.trim().isNotEmpty) return error.trim();
  if (error is Map) {
    final message = error['message'];
    if (message is String) return message;
  }
  return '';
}

/// The prompt a video request carries: the user's words plus the chosen style
/// pack's block, exactly as the image path does it.
String videoPrompt(String prompt, VideoOptions options, Iterable<ImageStyle> custom) =>
    withStyle(prompt, styleById(custom, options.style));
