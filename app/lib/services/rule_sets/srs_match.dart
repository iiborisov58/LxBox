import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import '../reachability/srs_reader.dart';

/// §723 — чем совпал запрос с rule-set'ом.
enum SrsHitKind { domain, suffix, keyword, regex, ip }

class SrsHit {
  const SrsHit(this.kind, this.value);

  final SrsHitKind kind;

  /// Сработавшее правило: домен, суффикс, keyword, regex или диапазон
  /// `from–to`.
  final String value;
}

/// §723 — индекс по разобранному `.srs` для проверки «есть ли здесь домен».
///
/// Матчинг — как у ядра: `domain` — точное совпадение; `domain_suffix` без
/// ведущей точки — сам домен и поддомены по границе метки, с точкой — только
/// поддомены; `domain_keyword` — подстрока; `domain_regex` — RegExp (Dart и
/// Go RE2 почти совпадают; regex, который Dart не принял, пропускается);
/// `ip_cidr` — попадание в диапазон.
class SrsIndex {
  SrsIndex(this.dump)
    : _domains = dump.domains.map((d) => d.toLowerCase()).toSet(),
      _suffixes = dump.domainSuffixes.map((d) => d.toLowerCase()).toSet();

  final SrsDump dump;
  final Set<String> _domains;
  final Set<String> _suffixes;
  late final List<(String, RegExp)> _regexes = [
    for (final r in dump.domainRegexes)
      if (_tryRegExp(r) case final re?) (r, re),
  ];

  static RegExp? _tryRegExp(String r) {
    try {
      return RegExp(r);
    } catch (_) {
      return null;
    }
  }

  int get ipv4Ranges => dump.ipRanges.where((r) => r.isV4).length;
  int get ipv6Ranges => dump.ipRanges.length - ipv4Ranges;

  /// Ответ на ввод пользователя: домен, IP или URL (берётся host). Null —
  /// не найдено или ввод пустой.
  SrsHit? match(String input) {
    final q = normalizeQuery(input);
    if (q == null) return null;
    final ip = InternetAddress.tryParse(q);
    if (ip != null) return _matchIp(ip.rawAddress);

    if (_domains.contains(q)) return SrsHit(SrsHitKind.domain, q);
    if (_suffixes.contains(q)) return SrsHit(SrsHitKind.suffix, q);
    for (var i = q.indexOf('.'); i >= 0; i = q.indexOf('.', i + 1)) {
      final dotted = q.substring(i); // ".example.com" — только поддомены
      if (_suffixes.contains(dotted)) return SrsHit(SrsHitKind.suffix, dotted);
      final bare = q.substring(i + 1); // "example.com" — домен и поддомены
      if (_suffixes.contains(bare)) return SrsHit(SrsHitKind.suffix, bare);
    }
    for (final k in dump.domainKeywords) {
      if (k.isNotEmpty && q.contains(k.toLowerCase())) {
        return SrsHit(SrsHitKind.keyword, k);
      }
    }
    for (final (src, re) in _regexes) {
      if (re.hasMatch(q)) return SrsHit(SrsHitKind.regex, src);
    }
    return null;
  }

  SrsHit? _matchIp(Uint8List a) {
    for (final r in dump.ipRanges) {
      if (r.from.length != a.length) continue;
      if (_cmp(r.from, a) <= 0 && _cmp(a, r.to) <= 0) {
        return SrsHit(SrsHitKind.ip, '${r.fromText}–${r.toText}');
      }
    }
    return null;
  }

  static int _cmp(Uint8List x, Uint8List y) {
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
  }

  /// Привести ввод к host: URL → host, регистр, хвостовая точка, скобки IPv6.
  static String? normalizeQuery(String input) {
    var s = input.trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s.contains('://')) {
      final h = Uri.tryParse(s)?.host;
      if (h == null || h.isEmpty) return null;
      s = h;
    }
    if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    return s.isEmpty ? null : s;
  }
}
