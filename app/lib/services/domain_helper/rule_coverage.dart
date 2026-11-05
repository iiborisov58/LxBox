import 'dart:io';
import 'dart:isolate';

import '../../models/custom_rule.dart';
import '../reachability/srs_reader.dart';
import '../rule_set_downloader.dart';
import '../rule_sets/srs_match.dart';

/// §724 — каким своим правилом хост уже совпадает.
class CoverHit {
  const CoverHit(this.ruleName, this.outbound, this.match);

  final String ruleName;

  /// Выход правила; пусто — у правила нет отдельного тега.
  final String outbound;

  /// Сработавший элемент (`domain_suffix github.com` и т.п.).
  final SrsHit match;
}

/// §724 — покрытие хостов своими правилами в порядке списка: первое
/// совпадение и есть то правило, что перехватит трафик раньше нового.
///
/// Учитываются только доменные условия. Порты, приложения, Wi-Fi правила
/// AND-ятся с ними и здесь не проверяются — поэтому это «может совпасть», а
/// не «совпадёт». Пресеты — не в первой версии (spec 724, Non-goals).
class RuleCoverage {
  RuleCoverage._(this._entries, this.missingSrsRules);

  final List<(CustomRule, SrsIndex)> _entries;

  /// Включённые `.srs`-правила, чьи файлы не скачаны: их покрытие неизвестно.
  final List<String> missingSrsRules;

  static const empty = RuleCoverage._fixed();
  const RuleCoverage._fixed() : _entries = const [], missingSrsRules = const [];

  /// [cachedPath] — тестовый шов вместо [RuleSetDownloader.cachedPath].
  static Future<RuleCoverage> build(
    List<CustomRule> rules, {
    String? excludeId,
    Future<String?> Function(String cacheId)? cachedPath,
  }) async {
    final path = cachedPath ?? RuleSetDownloader.cachedPath;
    final entries = <(CustomRule, SrsIndex)>[];
    final missing = <String>[];
    for (final r in rules) {
      if (!r.enabled || r.id == excludeId) continue;
      switch (r) {
        case CustomRuleInline():
          final d = SrsDump()
            ..domains.addAll(r.domains)
            ..domainSuffixes.addAll(r.domainSuffixes)
            ..domainKeywords.addAll(r.domainKeywords)
            ..domainRegexes.addAll(r.domainRegexes);
          if (d.domains.isEmpty &&
              d.domainSuffixes.isEmpty &&
              d.domainKeywords.isEmpty &&
              d.domainRegexes.isEmpty) {
            continue;
          }
          entries.add((r, SrsIndex(d)));
        case CustomRuleSrs():
          for (final id in r.cacheIds) {
            final p = await path(id);
            if (p == null) {
              if (!missing.contains(r.name)) missing.add(r.name);
              continue;
            }
            try {
              final bytes = await File(p).readAsBytes();
              final dump = await Isolate.run(() => readSrs(bytes));
              entries.add((r, SrsIndex(dump)));
            } catch (_) {
              if (!missing.contains(r.name)) missing.add(r.name);
            }
          }
        case CustomRulePreset() || CustomRuleJson():
          break;
      }
    }
    return RuleCoverage._(entries, missing);
  }

  CoverHit? coverOf(String host) {
    for (final (rule, idx) in _entries) {
      final m = idx.match(host);
      if (m != null) return CoverHit(rule.name, rule.outbound, m);
    }
    return null;
  }
}
