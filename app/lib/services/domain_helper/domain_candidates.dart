import 'dart:io' show InternetAddress;

import '../../screens/custom_rule_edit/punycode.dart';
import '../../screens/custom_rule_edit/validators.dart' as v;
import '../process_name.dart';
import '../traffic_profiler.dart';
import 'public_suffix.dart';

/// §724 — откуда пришёл кандидат.
enum CandidateSource { recorded, text, ruleSet }

/// Хост-кандидат и что о нём известно.
class DomainCandidate {
  DomainCandidate(this.host);

  final String host;
  final Set<CandidateSource> sources = {};

  /// Из записи: число соединений и выходы, которыми трафик ушёл сейчас.
  int connections = 0;
  final Set<String> outbounds = {};

  /// Из набора правил: элемент был `domain_suffix` (а не точным доменом).
  bool fromSuffix = false;
}

/// Привести строку к хосту правила: URL → host, регистр, порт, хвостовая
/// точка, ведущая точка суффикса, punycode. Null — не домен (IP, мусор).
String? normalizeHost(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  if (s.contains('://')) {
    final h = Uri.tryParse(s)?.host;
    if (h == null || h.isEmpty) return null;
    s = h;
  }
  final slash = s.indexOf('/');
  if (slash >= 0) s = s.substring(0, slash);
  final colon = s.lastIndexOf(':');
  if (colon > 0 && !s.contains(']') && s.indexOf(':') == colon) {
    s = s.substring(0, colon);
  }
  while (s.startsWith('.') || s.startsWith('*')) {
    s = s.substring(1);
  }
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty || InternetAddress.tryParse(s) != null) return null;
  final ascii = domainToAscii(s);
  if (!ascii.contains('.') || !v.isValidDomain(ascii)) return null;
  return ascii;
}

final _hostInText = RegExp(
  r'(?:[a-z][a-z0-9+.-]*://)?(?:\*\.)?(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+[\p{L}]{2,63}',
  caseSensitive: false,
  unicode: true,
);

/// Хосты из произвольного текста (подборка из чата, список, URL) — по порядку
/// появления, без повторов. Верхний уровень обязан быть в [psl]: так
/// отсекаются имена файлов вроде `index-v2.json`.
List<String> extractHosts(String text, PublicSuffixList psl) {
  final out = <String>[];
  final seen = <String>{};
  for (final m in _hostInText.allMatches(text)) {
    final h = normalizeHost(m.group(0)!);
    if (h == null || !seen.add(h)) continue;
    final tld = h.substring(h.lastIndexOf('.') + 1);
    if (!psl.isListedTld(tld)) continue;
    out.add(h);
  }
  return out;
}

/// Итог записи профайлера по приложениям: кандидаты и сколько соединений
/// прошло без домена (только IP) — их правилом по домену не поймать.
class RecordedHosts {
  const RecordedHosts(this.candidates, this.ipOnlyConnections);

  final List<DomainCandidate> candidates;
  final int ipOnlyConnections;
}

/// §724 — домены событий профайлера, чей владелец — один из [packages].
/// Без владельца — не берём: чужой трафик в правиле хуже пропущенного домена.
RecordedHosts hostsFromEvents(
  Iterable<TrafficEvent> events,
  Set<String> packages,
) {
  final byHost = <String, DomainCandidate>{};
  var ipOnly = 0;
  for (final e in events) {
    if (e.confidence == ConfidenceLevel.unattributed) continue;
    final pkg = packageNameFromProcess(e.process ?? '');
    if (!packages.contains(pkg)) continue;
    final isOpen =
        e.kind == TrafficEventKind.tcpOpen ||
        e.kind == TrafficEventKind.udpOpen;
    final host = normalizeHost(e.domain ?? '');
    if (host == null) {
      if (isOpen && (e.ip ?? '').isNotEmpty) ipOnly++;
      continue;
    }
    final c = byHost.putIfAbsent(host, () => DomainCandidate(host))
      ..sources.add(CandidateSource.recorded);
    if (isOpen) c.connections++;
    c.outbounds.addAll(e.outboundChain.take(1));
  }
  return RecordedHosts(byHost.values.toList(), ipOnly);
}

/// Группа кандидатов под одним регистрируемым доменом.
class CandidateGroup {
  CandidateGroup(this.key, {required this.suffixAllowed});

  /// Регистрируемый домен (eTLD+1) или сам хост, если домена у него нет.
  final String key;

  /// Можно ли предложить суффикс [key]. Нельзя, если хост сам публичный
  /// суффикс (`github.io`): суффикс захватил бы все сайты на нём.
  final bool suffixAllowed;

  final List<DomainCandidate> hosts = [];

  Set<CandidateSource> get sources => {for (final h in hosts) ...h.sources};
  int get connections => hosts.fold(0, (a, h) => a + h.connections);
}

/// Свернуть кандидатов по eTLD+1 (PSL с приватной секцией). Порядок групп —
/// по числу соединений, затем по имени.
List<CandidateGroup> groupCandidates(
  Iterable<DomainCandidate> candidates,
  PublicSuffixList psl,
) {
  final groups = <String, CandidateGroup>{};
  for (final c in candidates) {
    final reg = psl.registrable(c.host);
    final key = reg ?? c.host;
    final g = groups.putIfAbsent(
      key,
      () => CandidateGroup(key, suffixAllowed: reg != null),
    );
    final same = g.hosts.where((h) => h.host == c.host).firstOrNull;
    if (same != null) {
      same.sources.addAll(c.sources);
      same.connections += c.connections;
      same.outbounds.addAll(c.outbounds);
      same.fromSuffix |= c.fromSuffix;
    } else {
      g.hosts.add(c);
    }
  }
  final list = groups.values.toList()
    ..sort((a, b) {
      final c = b.connections.compareTo(a.connections);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  for (final g in list) {
    g.hosts.sort((a, b) => a.host.compareTo(b.host));
  }
  return list;
}
