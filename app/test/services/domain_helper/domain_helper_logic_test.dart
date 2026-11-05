import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/domain_helper/domain_candidates.dart';
import 'package:lxbox/services/domain_helper/exit_probe.dart';
import 'package:lxbox/services/domain_helper/public_suffix.dart';
import 'package:lxbox/services/domain_helper/rule_coverage.dart';
import 'package:lxbox/services/rule_sets/srs_match.dart';
import 'package:lxbox/services/traffic_profiler.dart';

/// §724 — логика помощника доменов: PSL, кандидаты, покрытие, проба выхода.
void main() {
  // Настоящий бандл: проверяем и разбор, и то, что нужные записи в нём есть.
  final psl = PublicSuffixList.parse(
    File(PublicSuffixList.assetPath).readAsStringSync(),
  );

  group('PSL', () {
    test('registrable domain, ICANN and private sections', () {
      expect(psl.registrable('api.github.com'), 'github.com');
      expect(psl.registrable('www.bbc.co.uk'), 'bbc.co.uk');
      // Приватная секция: общий хостинг не сворачивается в себя.
      expect(
        psl.registrable('release-assets.githubusercontent.com'),
        'release-assets.githubusercontent.com',
      );
      expect(psl.registrable('foo.github.io'), 'foo.github.io');
      expect(psl.registrable('github.io'), isNull);
      expect(psl.registrable('co.uk'), isNull);
    });

    test('wildcard and exception rules', () {
      final p = PublicSuffixList.parse('*.ck\n!www.ck\ncom\n');
      expect(p.publicSuffix('a.b.ck'), 'b.ck');
      expect(p.registrable('x.a.b.ck'), 'a.b.ck');
      expect(p.publicSuffix('www.ck'), 'ck');
      expect(p.registrable('www.ck'), 'www.ck');
    });
  });

  group('candidates', () {
    test('normalizeHost', () {
      expect(normalizeHost('https://F-Droid.org/packages/x'), 'f-droid.org');
      expect(normalizeHost('*.example.com.'), 'example.com');
      expect(normalizeHost('.example.com'), 'example.com');
      expect(normalizeHost('example.com:443'), 'example.com');
      expect(normalizeHost('1.2.3.4'), isNull);
      expect(normalizeHost('localhost'), isNull);
    });

    test('extractHosts from a chat-style list', () {
      const text = '''
F-Droid и IzzyOnDroid — в direct смело:
f-droid.org (покрывает и cloudflare.f-droid.org)
основные зеркала: ftp.fau.de, mirrors.dotsrc.org. Адрес — https://apt.izzysoft.de/fdroid/repo.
index-v2.json, github.com (покрывает api., codeload.)
''';
      expect(extractHosts(text, psl), [
        'f-droid.org',
        'cloudflare.f-droid.org',
        'ftp.fau.de',
        'mirrors.dotsrc.org',
        'apt.izzysoft.de',
        'github.com',
      ]);
    });

    test('hostsFromEvents keeps only the chosen apps and counts IP-only', () {
      TrafficEvent ev(
        String? domain,
        String proc, {
        TrafficEventKind kind = TrafficEventKind.tcpOpen,
        ConfidenceLevel c = ConfidenceLevel.verified,
      }) => TrafficEvent(
        ts: DateTime(2026),
        kind: kind,
        domain: domain,
        ip: '1.2.3.4',
        process: '$proc (u0_a1)',
        outboundChain: const ['vpn-1'],
        confidence: c,
      );
      final r = hostsFromEvents(
        [
          ev('f-droid.org', 'org.fdroid.fdroid'),
          ev('f-droid.org', 'org.fdroid.fdroid'),
          ev(
            'f-droid.org',
            'org.fdroid.fdroid',
            kind: TrafficEventKind.dnsResolve,
          ),
          ev(null, 'org.fdroid.fdroid'),
          ev('other.com', 'com.other'),
          ev('ghost.com', 'org.fdroid.fdroid', c: ConfidenceLevel.unattributed),
        ],
        {'org.fdroid.fdroid'},
      );
      expect(r.candidates.map((c) => c.host), ['f-droid.org']);
      expect(r.candidates.single.connections, 2);
      expect(r.candidates.single.outbounds, {'vpn-1'});
      expect(r.ipOnlyConnections, 1);
    });

    test('groupCandidates folds by eTLD+1, shared hosting stays exact', () {
      final g = groupCandidates([
        for (final h in [
          'api.github.com',
          'codeload.github.com',
          'release-assets.githubusercontent.com',
          'github.io',
        ])
          DomainCandidate(h)..sources.add(CandidateSource.text),
      ], psl);
      final byKey = {for (final x in g) x.key: x};
      expect(byKey['github.com']!.hosts.map((h) => h.host), [
        'api.github.com',
        'codeload.github.com',
      ]);
      expect(byKey['github.com']!.suffixAllowed, isTrue);
      expect(
        byKey['release-assets.githubusercontent.com']!.suffixAllowed,
        isTrue,
      );
      expect(byKey['github.io']!.suffixAllowed, isFalse);
    });
  });

  group('coverage', () {
    test(
      'first enabled matching rule wins, edited and disabled skipped',
      () async {
        final rules = <CustomRule>[
          CustomRuleInline(
            id: 'off',
            name: 'Off',
            enabled: false,
            domainSuffixes: ['github.com'],
          ),
          CustomRuleInline(
            id: 'self',
            name: 'Self',
            domainSuffixes: ['github.com'],
          ),
          CustomRuleSrs(
            name: 'Blocked',
            srsUrl: 'https://x/a.srs',
            outbound: 'vpn-1',
          ),
          CustomRuleInline(
            name: 'GH',
            domainSuffixes: ['github.com'],
            outbound: 'direct-out',
          ),
        ];
        final cov = await RuleCoverage.build(
          rules,
          excludeId: 'self',
          cachedPath: (_) async => null,
        );
        final hit = cov.coverOf('api.github.com')!;
        expect(hit.ruleName, 'GH');
        expect(hit.outbound, 'direct-out');
        expect(hit.match.kind, SrsHitKind.suffix);
        expect(cov.coverOf('gitlab.com'), isNull);
        expect(cov.missingSrsRules, ['Blocked']);
      },
    );
  });

  group('exit probe', () {
    test('direct works → direct', () async {
      final r = await checkExits(
        'a.com',
        proxyTag: 'vpn-1',
        probe: (tag, url, t) async => (204, ''),
      );
      expect(r.verdict, ExitVerdict.direct);
    });

    test(
      'only proxy answers → proxyOnly; TLS cert error counts as answer',
      () async {
        final r = await checkExits(
          'a.com',
          proxyTag: 'vpn-1',
          probe: (tag, url, t) async => tag == 'direct-out'
              ? (0, 'dial tcp 1.2.3.4:443: i/o timeout')
              : (0, 'x509: certificate is valid for b.com'),
        );
        expect(r.verdict, ExitVerdict.proxyOnly);
        expect(r.directDetail, isNot(contains('1.2.3.4')));
      },
    );

    test('final = direct-out → no proxy probe', () async {
      final tags = <String>[];
      final r = await checkExits(
        'a.com',
        proxyTag: 'direct-out',
        probe: (tag, url, t) async {
          tags.add(tag);
          throw Exception('down');
        },
      );
      expect(tags, ['direct-out']);
      expect(r.verdict, ExitVerdict.none);
    });
  });
}
