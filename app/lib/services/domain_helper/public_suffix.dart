import 'package:flutter/services.dart' show rootBundle;

import '../../screens/custom_rule_edit/punycode.dart';

/// §724 — Public Suffix List (publicsuffix.org, MPL-2.0), бандлится в
/// `assets/psl/public_suffix_list.dat`.
///
/// Нужен помощнику доменов, чтобы сворачивать хосты в суффиксы правила, не
/// захватывая чужое: `api.github.com` → `github.com`, а
/// `release-assets.githubusercontent.com` остаётся собой — `githubusercontent.com`
/// в приватной секции списка, это общее пространство имён. Приватная секция
/// учитывается намеренно: она и есть перечень общих хостингов (`cloudfront.net`,
/// `github.io`…), свернуть которые значило бы отправить в правило чужие сайты.
class PublicSuffixList {
  PublicSuffixList._(this._rules, this._wildcards, this._exceptions);

  final Set<String> _rules;
  final Set<String> _wildcards; // `*.ck` → хранится `ck`
  final Set<String> _exceptions; // `!www.ck` → `www.ck`

  static const assetPath = 'assets/psl/public_suffix_list.dat';

  static PublicSuffixList? _cached;

  static Future<PublicSuffixList> load() async =>
      _cached ??= parse(await rootBundle.loadString(assetPath));

  /// Разбор текста списка: строка — правило, `//` — комментарий.
  static PublicSuffixList parse(String text) {
    final rules = <String>{}, wild = <String>{}, exc = <String>{};
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      final r = domainToAscii(line.split(RegExp(r'\s')).first.toLowerCase());
      if (r.startsWith('!')) {
        exc.add(r.substring(1));
      } else if (r.startsWith('*.')) {
        wild.add(r.substring(2));
      } else {
        rules.add(r);
      }
    }
    return PublicSuffixList._(rules, wild, exc);
  }

  /// Публичный суффикс хоста по алгоритму publicsuffix.org (правило по
  /// умолчанию `*` — последняя метка).
  String publicSuffix(String host) {
    final labels = host.split('.');
    for (var i = 0; i < labels.length; i++) {
      final cand = labels.sublist(i).join('.');
      if (_exceptions.contains(cand)) return labels.sublist(i + 1).join('.');
      if (_rules.contains(cand)) return cand;
      if (i + 1 < labels.length &&
          _wildcards.contains(labels.sublist(i + 1).join('.'))) {
        return cand;
      }
    }
    return labels.last;
  }

  /// Регистрируемый домен (eTLD+1). Null — хост сам публичный суффикс
  /// (`co.uk`, `github.io`): своего домена у него нет.
  String? registrable(String host) {
    final suffix = publicSuffix(host);
    if (host == suffix || !host.endsWith('.$suffix')) return null;
    final rest = host.substring(0, host.length - suffix.length - 1);
    return '${rest.split('.').last}.$suffix';
  }

  bool isPublicSuffix(String host) => publicSuffix(host) == host;

  /// Верхний уровень явно есть в списке (правило по умолчанию `*` не в счёт):
  /// отсекает «домены» вроде `index-v2.json`.
  bool isListedTld(String tld) => _rules.contains(tld);
}
