import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Colours for the model's Markdown, taken from this app's own scheme.
///
/// The renderer keeps its own copy of Material and looks its colours up in
/// that: on this app's surface the table header came out near-white with text
/// of the same tone, and inline code was inked darker than its own fill. Both
/// were laid out and unreadable, so every colour that decides legibility is
/// stated here — with a value, never a role the renderer would resolve in a
/// scheme this app does not own.
GptMarkdownThemeData studioMarkdownTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final ink = scheme.onSurface;
  final dark = scheme.brightness == Brightness.dark;
  final text = theme.textTheme;
  final inlineCode = InlineCodeStyle(
    color: ink,
    backgroundColor: ink.withValues(alpha: dark ? .14 : .10),
    borderColor: ink.withValues(alpha: dark ? .34 : .28),
  );
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
    inlineCode: inlineCode,
    styleSheet: const GptMarkdownStyleSheet().copyWith(
      inlineCode: inlineCode,
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
