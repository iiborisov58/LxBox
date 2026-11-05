import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/rule_sets/rule_set_sources.dart';

/// §723 — реестр источников `.srs`: черновик, пока лаунчер не принял его в
/// контракт.
void main() {
  final registry = File(RuleSetSources.registryPath);
  final draft = File(RuleSetSources.draftPath);
  final file = registry.existsSync() ? registry : draft;

  // Ровно одно место: файл приехал контрактом — черновик снимается, иначе
  // молча расходились бы две копии и читалась бы только первая.
  test('sources live either in the registry or in the draft', () {
    expect(
      registry.existsSync() != draft.existsSync(),
      isTrue,
      reason:
          'rule_set_sources.json: registry=${registry.existsSync()}, '
          'draft=${draft.existsSync()}',
    );
  });

  test('registry parses and holds the four agreed sources', () {
    final reg = RuleSetSources.parse(file.readAsStringSync());
    expect(reg.listTtl, const Duration(hours: 24));
    expect(reg.sources.map((s) => s.repo), [
      'runetfreedom/russia-v2ray-rules-dat',
      'SagerNet/sing-geosite',
      'SagerNet/sing-geoip',
      'MetaCubeX/meta-rules-dat',
      'legiz-ru/sb-rule-sets',
    ]);
    for (final s in reg.sources) {
      expect(s.dirs, isNotEmpty, reason: s.id);
    }
    // Репозитории больше 50 МБ jsDelivr не листает — fallback там бесполезен.
    final big = reg.sources.where(
      (s) => s.id == 'runetfreedom' || s.id == 'metacubex',
    );
    expect(big.every((s) => !s.jsdelivrList), isTrue);
  });

  Map<String, dynamic> base() => {
    'v': 1,
    'rule_set_sources': {
      'list_ttl_hours': {'value': 24},
      'sources': [
        {
          'id': 'a',
          'title': 'A',
          'repo': 'o/r',
          'ref': 'main',
          'dirs': [
            {'path': '', 'kind': 'geosite'},
          ],
        },
      ],
    },
  };

  Map<String, dynamic> src(Map<String, dynamic> j) =>
      ((j['rule_set_sources'] as Map)['sources'] as List).first
          as Map<String, dynamic>;

  test('minimal registry parses with defaults', () {
    final reg = RuleSetSources.parse(jsonEncode(base()));
    final s = reg.sources.single;
    expect(s.jsdelivrList, isFalse);
    expect(s.dirs.single.kind, RuleSetKind.geosite);
    expect(s.homepage, 'https://github.com/o/r/tree/main');
  });

  final broken = <String, void Function(Map<String, dynamic>)>{
    'wrong version': (j) => j['v'] = 2,
    'duplicate id': (j) {
      final l = (j['rule_set_sources'] as Map)['sources'] as List;
      l.add(l.first);
    },
    'repo without owner': (j) => src(j)['repo'] = 'r',
    'no dirs': (j) => src(j)['dirs'] = [],
    'unknown kind': (j) => src(j)['dirs'] = [
      {'path': '', 'kind': 'asn'},
    ],
    'leading slash': (j) => src(j)['dirs'] = [
      {'path': '/geo', 'kind': 'geoip'},
    ],
    'zero ttl': (j) =>
        (j['rule_set_sources'] as Map)['list_ttl_hours'] = {'value': 0},
  };
  for (final MapEntry(:key, :value) in broken.entries) {
    test('rejects: $key', () {
      final j = base();
      value(j);
      expect(
        () => RuleSetSources.parse(jsonEncode(j)),
        throwsA(isA<FormatException>()),
      );
    });
  }
}
