import 'dart:convert';

import 'models.dart';

/// A deliberately rough token count, used only to decide when a conversation
/// needs compacting. There is no tokenizer in the app and no model-specific
/// vocabulary to load: overestimating a little is safe, because it only makes
/// the summary start earlier.
int estimateTokens(String text) {
  var tokens = 0.0;
  for (final rune in text.runes) {
    tokens += _isWide(rune) ? 1.0 : .25;
  }
  return tokens.ceil();
}

/// CJK, Hangul and emoji take roughly one token per character; most Latin
/// characters take about a quarter. Other scripts sit near the CJK side.
bool _isWide(int rune) =>
    rune >= 0x2E80 ||
    (rune >= 0x1100 && rune <= 0x11FF) ||
    (rune >= 0x1F000 && rune <= 0x1FAFF);

/// Everything a history entry puts on the wire, including the JSON of tool
/// arguments. The per-entry constant covers the role and message framing.
int estimateHistoryTokens(Iterable<ChatEntry> history) {
  var total = 0;
  for (final entry in history) {
    total += 4;
    total += estimateTokens(entry.text);
    total += estimateTokens(entry.reasoning);
    total += estimateTokens(entry.assetIds.join(' '));
    for (final call in entry.calls) {
      total += 4;
      total += estimateTokens(call.name);
      total += estimateTokens(jsonEncode(call.arguments));
    }
  }
  return total;
}
