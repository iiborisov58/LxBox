import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/reachability/srs_reader.dart';
import 'package:lxbox/services/rule_sets/srs_match.dart';

/// §723 — «есть ли домен / IP в этом rule-set'е», семантика ядра.
void main() {
  final dump = SrsDump()
    ..domains.add('exact.example')
    ..domainSuffixes.addAll(['youtube.com', '.only-sub.net'])
    ..domainKeywords.add('torrent')
    ..domainRegexes.addAll([r'^ads\d+\.', r'(?P<bad'])
    ..ipRanges.addAll([
      SrsIpRange(
        Uint8List.fromList([10, 0, 0, 0]),
        Uint8List.fromList([10, 0, 0, 255]),
      ),
      SrsIpRange(
        Uint8List.fromList([0x20, 0x01, 0x0d, 0xb8, ...List.filled(12, 0)]),
        Uint8List.fromList([0x20, 0x01, 0x0d, 0xb8, ...List.filled(12, 0xff)]),
      ),
    ]);
  final idx = SrsIndex(dump);

  SrsHit? m(String q) => idx.match(q);

  test('domain is exact', () {
    expect(m('exact.example')?.kind, SrsHitKind.domain);
    expect(m('sub.exact.example'), isNull);
  });

  test('bare suffix matches itself and subdomains at label boundary', () {
    expect(m('youtube.com')?.value, 'youtube.com');
    expect(m('www.youtube.com')?.value, 'youtube.com');
    expect(m('notyoutube.com'), isNull);
  });

  test('dotted suffix matches only subdomains', () {
    expect(m('only-sub.net'), isNull);
    expect(m('a.only-sub.net')?.value, '.only-sub.net');
  });

  test('keyword and regex; invalid regex is skipped', () {
    expect(m('my-torrent.site')?.kind, SrsHitKind.keyword);
    expect(m('ads12.tracker.io')?.kind, SrsHitKind.regex);
    expect(m('plain.io'), isNull);
  });

  test('input is normalized: case, URL, trailing dot', () {
    expect(m('  WWW.YouTube.COM. ')?.kind, SrsHitKind.suffix);
    expect(m('https://m.youtube.com/watch?v=1')?.kind, SrsHitKind.suffix);
    expect(m(''), isNull);
  });

  test('IPv4 and IPv6 ranges', () {
    expect(m('10.0.0.7')?.value, '10.0.0.0–10.0.0.255');
    expect(m('10.0.1.1'), isNull);
    expect(m('2001:db8::1')?.kind, SrsHitKind.ip);
    expect(m('[2001:db8::1]')?.kind, SrsHitKind.ip);
    expect(m('2001:db9::1'), isNull);
    expect(idx.ipv4Ranges, 1);
    expect(idx.ipv6Ranges, 1);
  });
}
