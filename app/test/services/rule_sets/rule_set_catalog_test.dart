import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/reachability/srs_reader.dart';
import 'package:lxbox/services/rule_sets/rule_set_catalog.dart';
import 'package:lxbox/services/rule_sets/rule_set_sources.dart';

/// §723 — списки файлов источников, URL зеркал, поиск, кеш.
void main() {
  const big = RuleSetSource(
    id: 'big',
    title: 'Big',
    repo: 'o/big',
    ref: 'release',
    dirs: [
      RuleSetSourceDir('sing-box/rule-set-geosite', RuleSetKind.geosite),
      RuleSetSourceDir('sing-box/rule-set-geoip', RuleSetKind.geoip),
    ],
  );
  const small = RuleSetSource(
    id: 'small',
    title: 'Small',
    repo: 'o/small',
    ref: 'main',
    jsdelivrList: true,
    dirs: [RuleSetSourceDir('', RuleSetKind.mixed)],
  );
  const reg = RuleSetSources([big, small], Duration(hours: 24));

  String tree(List<String> names) => jsonEncode({
    'tree': [
      for (final n in names) {'path': n, 'type': 'blob', 'size': 10},
      {'path': 'nested', 'type': 'tree'},
      {'path': 'README.md', 'type': 'blob', 'size': 1},
    ],
    'truncated': false,
  });

  group('URLs', () {
    const e = RuleSetEntry(
      sourceId: 'big',
      dir: 'sing-box/rule-set-geosite',
      name: 'geosite-youtube.srs',
      kind: RuleSetKind.geosite,
    );

    test('mirrors', () {
      expect(
        ruleSetUrl(big, e, RuleSetMirror.github),
        'https://raw.githubusercontent.com/o/big/release/sing-box/rule-set-geosite/geosite-youtube.srs',
      );
      expect(
        ruleSetUrl(big, e, RuleSetMirror.jsdelivr),
        'https://cdn.jsdelivr.net/gh/o/big@release/sing-box/rule-set-geosite/geosite-youtube.srs',
      );
    });

    test('tree API addresses one directory, root without colon', () {
      expect(
        gitTreeUri(big, big.dirs.first).toString(),
        'https://api.github.com/repos/o/big/git/trees/release:sing-box/rule-set-geosite',
      );
      expect(
        gitTreeUri(small, small.dirs.first).toString(),
        'https://api.github.com/repos/o/small/git/trees/main',
      );
    });

    test('root entry has no leading slash', () {
      const r = RuleSetEntry(
        sourceId: 'small',
        dir: '',
        name: 'x.srs',
        kind: RuleSetKind.mixed,
      );
      expect(
        ruleSetUrl(small, r, RuleSetMirror.github),
        'https://raw.githubusercontent.com/o/small/main/x.srs',
      );
    });
  });

  group('parsing', () {
    test('git tree keeps only .srs blobs', () {
      final l = parseGitTree(tree(['a.srs', 'b.srs']), big, big.dirs.first);
      expect(l.map((e) => e.name), ['a.srs', 'b.srs']);
      expect(l.first.size, 10);
      expect(l.first.kind, RuleSetKind.geosite);
    });

    test('jsDelivr flat keeps only files directly in the directory', () {
      final body = jsonEncode({
        'files': [
          {'name': '/a.srs', 'size': 5},
          {'name': '/.github/other/b.srs'},
          {'name': '/c.json'},
        ],
      });
      final l = parseJsdelivrFlat(body, small, small.dirs.first);
      expect(l.map((e) => e.path), ['a.srs']);
    });
  });

  group('search', () {
    RuleSetEntry e(String name, RuleSetKind k, [String src = 'big']) =>
        RuleSetEntry(sourceId: src, dir: '', name: name, kind: k);
    final all = [
      e('geosite-youtube-music.srs', RuleSetKind.geosite),
      e('geosite-youtube.srs', RuleSetKind.geosite),
      e('geosite-not-youtube.srs', RuleSetKind.geosite),
      e('geoip-ru.srs', RuleSetKind.geoip),
      e('ru-mixed.srs', RuleSetKind.mixed, 'small'),
    ];

    test('exact stem, then prefix, then substring', () {
      expect(searchRuleSets(all, 'YouTube').map((x) => x.name), [
        'geosite-youtube.srs',
        'geosite-youtube-music.srs',
        'geosite-not-youtube.srs',
      ]);
    });

    test('kind filter lets mixed through', () {
      expect(
        searchRuleSets(all, 'ru', kind: RuleSetKind.geoip).map((x) => x.name),
        ['geoip-ru.srs', 'ru-mixed.srs'],
      );
    });

    test('source filter', () {
      expect(
        searchRuleSets(all, '', sources: {'small'}).single.name,
        'ru-mixed.srs',
      );
    });
  });

  group('load', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('rsc'));
    tearDown(() => tmp.deleteSync(recursive: true));

    RuleSetCatalog catalog(MockClient c, DateTime now) => RuleSetCatalog(
      client: c,
      cacheFile: () async => File('${tmp.path}/catalog.json'),
      now: () => now,
    );

    test(
      'fetches every directory, then serves from cache within TTL',
      () async {
        final calls = <String>[];
        final c = MockClient((r) async {
          calls.add(r.url.toString());
          if (r.url.path.endsWith('geosite')) {
            return http.Response(tree(['s.srs']), 200);
          }
          if (r.url.path.endsWith('geoip')) {
            return http.Response(tree(['i.srs']), 200);
          }
          return http.Response(tree(['m.srs']), 200);
        });
        final t0 = DateTime(2026, 11, 5, 12);
        final a = await catalog(c, t0).load(reg);
        expect(a['big']!.entries.map((e) => e.name), ['s.srs', 'i.srs']);
        expect(a['small']!.entries.single.name, 'm.srs');
        expect(calls, hasLength(3));

        final b = await catalog(c, t0.add(const Duration(hours: 23))).load(reg);
        expect(calls, hasLength(3), reason: 'свежий кеш — без сети');
        expect(b['big']!.entries, hasLength(2));

        await catalog(c, t0.add(const Duration(hours: 25))).load(reg);
        expect(calls, hasLength(6), reason: 'кеш истёк');

        await catalog(
          c,
          t0.add(const Duration(hours: 25)),
        ).load(reg, force: true);
        expect(calls, hasLength(9));
      },
    );

    test('GitHub failure falls back to jsDelivr only where allowed', () async {
      final c = MockClient((r) async {
        if (r.url.host == 'api.github.com') return http.Response('rate', 403);
        return http.Response(
          jsonEncode({
            'files': [
              {'name': '/m.srs'},
            ],
          }),
          200,
        );
      });
      final l = await catalog(c, DateTime(2026)).load(reg);
      expect(l['small']!.entries.single.name, 'm.srs');
      expect(l['small']!.error, isNull);
      expect(l['big']!.entries, isEmpty);
      expect(l['big']!.error, contains('403'));
    });

    test('failed refresh keeps the stale list and reports the error', () async {
      var fail = false;
      final c = MockClient(
        (r) async =>
            fail ? http.Response('', 500) : http.Response(tree(['x.srs']), 200),
      );
      final t0 = DateTime(2026, 11, 5);
      await catalog(c, t0).load(reg);
      fail = true;
      final l = await catalog(c, t0).load(reg, force: true);
      expect(l['big']!.entries, isNotEmpty);
      expect(l['big']!.fetchedAt, t0);
      expect(l['big']!.error, contains('500'));
    });
  });

  group('fetchAndRead', () {
    // Пустой, но корректный rule-set: магия, версия, zlib(uvarint 0).
    final emptySrs = [
      0x53,
      0x52,
      0x53,
      1,
      ...zlib.encode([0]),
    ];

    test('reads a valid file', () async {
      final c = MockClient((_) async => http.Response.bytes(emptySrs, 200));
      final d = await RuleSetCatalog(client: c).fetchAndRead('https://x/a.srs');
      expect(d.domains, isEmpty);
    });

    test('not an srs → format error', () async {
      final c = MockClient((_) async => http.Response('<html>', 200));
      expect(
        RuleSetCatalog(client: c).fetchAndRead('https://x/a.srs'),
        throwsA(isA<SrsFormatException>()),
      );
    });

    test('HTTP error', () async {
      final c = MockClient((_) async => http.Response('', 404));
      expect(
        RuleSetCatalog(client: c).fetchAndRead('https://x/a.srs'),
        throwsA(isA<HttpException>()),
      );
    });
  });
}
