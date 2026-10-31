import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Colours for the model's Markdown, taken from this app's own scheme.
///
/// The package falls back to whatever colour scheme it can find, and on this
/// app's surface that produced a near-white table header carrying text of the
/// same tone, and inline code whose ink was darker than its own fill. Both were
/// present in the layout and unreadable on screen, so every colour that
/// decides legibility is stated here instead of being inherited.
GptMarkdownThemeData studioMarkdownTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final ink = scheme.onSurface;
  final text = theme.textTheme;
  return GptMarkdownThemeData(brightness: scheme.brightness).copyWith(
    h1: text.headlineSmall?.copyWith(color: ink, fontWeight: FontWeight.w700),
    h2: text.titleLarge?.copyWith(color: ink, fontWeight: FontWeight.w700),
    h3: text.titleMedium?.copyWith(color: ink, fontWeight: FontWeight.w600),
    h4: text.titleSmall?.copyWith(color: ink, fontWeight: FontWeight.w600),
    h5: text.bodyLarge?.copyWith(color: ink, fontWeight: FontWeight.w600),
    h6: text.bodyMedium?.copyWith(color: ink, fontWeight: FontWeight.w600),
    linkColor: scheme.primary,
    linkHoverColor: scheme.primary,
    hrLineColor: scheme.outlineVariant,
    inlineCode: const InlineCodeStyle().resolve(scheme),
    styleSheet: const GptMarkdownStyleSheet().copyWith(
      table: TableStyle(
        borderColor: scheme.outlineVariant,
        headerBackground: scheme.surfaceContainerHigh,
        headerTextStyle: TextStyle(
          color: ink,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
