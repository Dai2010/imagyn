import 'package:flutter/services.dart';

/// Keeps the Android process in the foreground while a turn runs, and posts a
/// notification when the turn ends while no activity is on screen.
///
/// A thin wrapper on purpose: the platform decides whether a notification is
/// needed (it knows whether an activity is visible), and every failure here is
/// swallowed — a refused notification permission must never fail a turn.
class Background {
  static const _channel = MethodChannel('app.imagyn/background');

  static Future<void> begin({required String title, required String body}) =>
      _call('start', {'title': title, 'body': body});

  static Future<void> end() => _call('stop');

  static Future<void> notify({required String title, required String body}) =>
      _call('notify', {'title': title, 'body': body});

  static Future<void> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object {
      // Desktop has no such channel, a plain unit test has no binding, and a
      // denied permission or refused service start is not a task failure.
      // Background support must never be able to fail a turn.
    }
  }
}
