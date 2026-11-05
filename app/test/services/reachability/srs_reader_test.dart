import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/reachability/reachability_logic.dart';
import 'package:lxbox/services/reachability/srs_reader.dart';

/// §721 — разбор `.srs`. Энкодер ниже — порт `newSuccinctSet` /
/// `NewMatcher` (sing `common/domain`) и `srs.Write` ядра: парсер сверяется с
/// тем, как файл пишет само ядро (v1 legacy-суффиксы и v2+ `\n`).
void main() {
  group('readSrs', () {
    test('v1: domain + legacy suffix (\\r.x + x) разворачиваются как Dump()', () {
      final data = _srs(1, [
        _domainItem(domains: ['exact.example.org'], suffixes: ['blocked.com'],
            legacy: true),
      ]);
      final d = readSrs(data);
      expect(d.domains, ['exact.example.org']);
      expect(d.domainSuffixes, ['blocked.com']);
    });

    test('v2+: суффикс с \\n-меткой', () {
      final data = _srs(3, [
        _domainItem(domains: [], suffixes: ['a.net', 'b.org'], legacy: false),
      ]);
      expect(readSrs(data).domainSuffixes..sort(), ['a.net', 'b.org']);
    });

    test('keyword/regex и ip_cidr читаются в свои поля', () {
      final data = _srs(1, [
        [
          ..._strItem(3, ['tracker']),
          ..._strItem(4, [r'^.*\.bad$']),
          ..._ipItem([
            ([1, 1, 1, 1], [1, 1, 1, 1]),
            ([10, 0, 0, 0], [10, 0, 255, 255]),
          ]),
        ],
      ]);
      final d = readSrs(data);
      expect(d.domainKeywords, ['tracker']);
      expect(d.domainRegexes, [r'^.*\.bad$']);
      expect(d.ipRanges.length, 2);
      expect(d.ipRanges.first.fromText, '1.1.1.1');
      expect(d.ipRanges.first.sizeV4, 1);
      expect(d.ipRanges.last.sizeV4, 65536);
    });

    test('логическое правило: вложенные правила разбираются', () {
      final inner = [0, ..._domainItem(domains: ['x.io'], suffixes: [], legacy: true), 0xFF, 0];
      final body = <int>[
        ..._uvarint(1),
        1, 1, ..._uvarint(1), ...inner, 0, // logical(or, 1 rule, invert=false)
      ];
      final d = readSrs(_container(1, body));
      expect(d.domains, ['x.io']);
    });

    test('мусор → SrsFormatException', () {
      expect(() => readSrs(Uint8List.fromList([1, 2, 3, 4, 5])),
          throwsA(isA<SrsFormatException>()));
      final truncated = _srs(1, [_strItem(3, ['abc'])]);
      expect(() => readSrs(Uint8List.sublistView(truncated, 0, 10)),
          throwsA(isA<SrsFormatException>()));
    });
  });

  group('buildCandidates', () {
    test('keyword и regex отбрасываются, domain и suffix — хосты', () {
      final d = SrsDump()
        ..domains.add('Exact.Example.org')
        ..domainSuffixes.addAll(['blocked.com', 'ru', '*.wild.net', 'xn--p1ai.xn--p1ai'])
        ..domainKeywords.add('keyword.com')
        ..domainRegexes.add(r'regex\.com');
      final c = buildCandidates(d, null);
      expect(c.hosts, ['blocked.com', 'exact.example.org', 'xn--p1ai.xn--p1ai']);
      expect(c.hosts, isNot(contains('keyword.com')));
      expect(c.ips, isEmpty);
    });

    test('geoip: только IPv4-диапазоны малого размера', () {
      final ip = SrsDump()
        ..ipRanges.addAll([
          SrsIpRange(Uint8List.fromList([1, 2, 3, 4]), Uint8List.fromList([1, 2, 3, 4])),
          SrsIpRange(Uint8List.fromList([5, 6, 7, 0]), Uint8List.fromList([5, 6, 7, 3])),
          SrsIpRange(Uint8List.fromList([8, 0, 0, 0]), Uint8List.fromList([8, 0, 0, 255])),
          SrsIpRange(Uint8List(16), Uint8List(16)),
        ]);
      expect(buildCandidates(null, ip).ips, ['1.2.3.4', '5.6.7.0']);
    });
  });
}

// ─── энкодер (порт ядра) ──────────────────────────────────────────────────────

Uint8List _srs(int version, List<List<int>> rules) {
  final body = <int>[..._uvarint(rules.length)];
  for (final items in rules) {
    body
      ..add(0) // default rule
      ..addAll(items)
      ..add(0xFF)
      ..add(0); // invert=false
  }
  return _container(version, body);
}

Uint8List _container(int version, List<int> body) =>
    Uint8List.fromList([0x53, 0x52, 0x53, version, ...zlib.encode(body)]);

List<int> _uvarint(int v) {
  final out = <int>[];
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

List<int> _strItem(int type, List<String> values) => [
      type,
      ..._uvarint(values.length),
      for (final v in values) ...[..._uvarint(utf8.encode(v).length), ...utf8.encode(v)],
    ];

List<int> _ipItem(List<(List<int>, List<int>)> ranges) {
  final out = <int>[6, 1];
  final len = ByteData(8)..setUint64(0, ranges.length);
  out.addAll(len.buffer.asUint8List());
  for (final (from, to) in ranges) {
    out
      ..addAll(_uvarint(from.length))
      ..addAll(from)
      ..addAll(_uvarint(to.length))
      ..addAll(to);
  }
  return out;
}

String _rev(String s) => String.fromCharCodes(s.runes.toList().reversed);

/// `NewMatcher` ядра: legacy (v1) — `x` + `\r.x`; иначе `\nx`.
List<int> _domainItem({
  required List<String> domains,
  required List<String> suffixes,
  required bool legacy,
}) {
  final keys = <String>{};
  for (final s in suffixes) {
    if (legacy) {
      keys
        ..add(_rev(s))
        ..add(_rev('\r.$s'));
    } else {
      keys.add(_rev('\n$s'));
    }
  }
  keys.addAll(domains.map(_rev));
  final sorted = keys.map(utf8.encode).toList()
    ..sort((a, b) {
      for (var i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) return a[i] - b[i];
      }
      return a.length - b.length;
    });
  return [2, ..._succinct(sorted)];
}

/// `newSuccinctSet` + `Write` (версия 0, uint64 BE с uvarint-длиной).
List<int> _succinct(List<List<int>> keys) {
  final leaves = <int>[];
  final bitmap = <int>[];
  final labels = <int>[];
  void setBit(List<int> bm, int i) {
    while ((i >> 6) >= bm.length) {
      bm.add(0);
    }
    bm[i >> 6] |= 1 << (i & 63);
  }

  void grow(List<int> bm, int i) {
    while ((i >> 6) >= bm.length) {
      bm.add(0);
    }
  }

  var lIdx = 0;
  final queue = <(int, int, int)>[(0, keys.length, 0)];
  for (var i = 0; i < queue.length; i++) {
    var (s, e, col) = queue[i];
    if (col == keys[s].length) {
      s++;
      setBit(leaves, i);
    }
    for (var j = s; j < e;) {
      final frm = j;
      while (j < e && keys[j][col] == keys[frm][col]) {
        j++;
      }
      queue.add((frm, j, col + 1));
      labels.add(keys[frm][col]);
      grow(bitmap, lIdx);
      lIdx++;
    }
    setBit(bitmap, lIdx);
    lIdx++;
  }

  List<int> u64s(List<int> v) {
    final out = <int>[..._uvarint(v.length)];
    for (final w in v) {
      final b = ByteData(8)..setUint64(0, w);
      out.addAll(b.buffer.asUint8List());
    }
    return out;
  }

  return [0, ...u64s(leaves), ...u64s(bitmap), ..._uvarint(labels.length), ...labels];
}
