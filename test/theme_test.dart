import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/main.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('desktop themes ask for the platform UI font', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final windows = studioTheme(Brightness.light);
    expect(windows.textTheme.bodyMedium?.fontFamily, 'Segoe UI');
    expect(
      windows.textTheme.bodyMedium?.fontFamilyFallback,
      contains('Microsoft YaHei'),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final linux = studioTheme(Brightness.light);
    expect(linux.textTheme.bodyMedium?.fontFamily, 'Noto Sans');
    expect(
      linux.textTheme.bodyMedium?.fontFamilyFallback,
      contains('Noto Sans CJK SC'),
    );
  });

  test('mobile and macOS keep the font Material already picks', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(studioTheme(Brightness.light).textTheme.bodyMedium?.fontFamily, isNot('Segoe UI'));

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(studioTheme(Brightness.light).textTheme.bodyMedium?.fontFamily, isNot('Segoe UI'));
  });
}
