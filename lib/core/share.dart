import 'package:share_plus/share_plus.dart';

/// Hands one local file to the system share sheet.
///
/// A function rather than a direct call, so a test can capture the path
/// without a platform channel. The share sheet is also the "open with" path on
/// Android: every app that can read the type is offered there.
typedef ShareFile = Future<void> Function(String path, String? subject);

Future<void> shareWithSystem(String path, String? subject) async {
  await SharePlus.instance.share(
    ShareParams(files: [XFile(path)], subject: subject),
  );
}
