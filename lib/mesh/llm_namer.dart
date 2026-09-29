import 'scan_summary.dart';

/// llm_namer — OPTIONAL, on-device, phrasing only.
///
/// The deterministic ScanSummary is the product and the ground truth. This is a
/// thin nicety on top: if an on-device tiny language model is available (Apple
/// Foundation Models on iOS 18+, wired through a platform channel), it can make
/// the name/description warmer or more natural — but it is FED the measured facts
/// and told to only rephrase them, never add. No model → callers use ScanSummary
/// directly and nothing is lost.
///
/// Doctrine (matches the rest of Ankur's stack): model-free by default; the LLM
/// is a rephraser you can turn off, never the source of truth. It must not invent
/// a room type, a piece of furniture, or a number the scan didn't measure.

/// Pluggable backend so the model stays out of this pure module. On iOS this is
/// backed by Foundation Models via a MethodChannel; in tests it's a fake.
abstract class TinyLlm {
  /// True only when a real on-device model is loaded and consented to.
  bool get available;

  /// Rephrase [text], constrained by [system]. Returns null on any failure so the
  /// caller falls back to the deterministic string.
  Future<String?> rephrase({required String system, required String text});
}

class LlmNamer {
  LlmNamer(this._llm);
  final TinyLlm _llm;

  static const _system =
      'You rename a 3D scan. You are given a factual, measured description. '
      'Rephrase it into a short, natural name or one warm sentence. '
      'Rules: use ONLY the facts given — never invent a room, object, furniture, '
      'material, or number. Keep every measurement exactly as given. If unsure, '
      'return the facts as-is. No emojis, no marketing.';

  /// A natural name. Falls back to the deterministic name when there's no model
  /// or the model fails — so behaviour is identical without a model.
  Future<String> name(ScanFacts f) async {
    final deterministic = ScanSummary.suggestName(f);
    if (!_llm.available) return deterministic;
    final out = await _llm.rephrase(
      system: _system,
      text: 'Facts: ${ScanSummary.describe(f)}\nSuggested name: $deterministic\n'
          'Give one short name (max 6 words).',
    );
    final cleaned = out?.trim();
    // guard: reject an empty/absurdly long answer → keep the honest one
    if (cleaned == null || cleaned.isEmpty || cleaned.length > 60) {
      return deterministic;
    }
    return cleaned;
  }

  /// A natural one-line description; same fall-back contract.
  Future<String> describe(ScanFacts f) async {
    final deterministic = ScanSummary.describe(f);
    if (!_llm.available) return deterministic;
    final out = await _llm.rephrase(
      system: _system,
      text: 'Facts: $deterministic\nRephrase as one warm, natural sentence, '
          'keeping every number.',
    );
    final cleaned = out?.trim();
    if (cleaned == null || cleaned.isEmpty || cleaned.length > 300) {
      return deterministic;
    }
    return cleaned;
  }
}

/// The no-op backend used by default and in tests: never available, so the app is
/// fully functional and honest without any model.
class NoTinyLlm implements TinyLlm {
  const NoTinyLlm();
  @override
  bool get available => false;
  @override
  Future<String?> rephrase({required String system, required String text}) async => null;
}
