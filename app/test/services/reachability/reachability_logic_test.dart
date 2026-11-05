import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/reachability/reachability_logic.dart';

/// §721 — чистая логика проверки доступности: выборка с ротацией, правило
/// «хотя бы один из N», вердикт по ответу ядра, ограничитель реакций.
void main() {
  group('ReachabilitySampler', () {
    final hosts = [for (var i = 0; i < 20; i++) 'h$i.example'];

    test('N целей, без повторов внутри выборки', () {
      final s = ReachabilitySampler(random: Random(1));
      final t = s.sample(hosts: hosts, ips: const [], count: 4);
      expect(t.length, 4);
      expect(t.toSet().length, 4);
      expect(t.every((x) => !x.isIp), isTrue);
    });

    test('ротация: цели прошлой проверки подряд не повторяются', () {
      final s = ReachabilitySampler(random: Random(7));
      var prev = s.sample(hosts: hosts, ips: const [], count: 5).toSet();
      for (var i = 0; i < 50; i++) {
        final next = s.sample(hosts: hosts, ips: const [], count: 5).toSet();
        expect(next.intersection(prev), isEmpty);
        prev = next;
      }
    });

    test('кандидатов мало — повтор допустим, выборка не пустеет', () {
      final s = ReachabilitySampler(random: Random(3));
      final small = ['a.example', 'b.example', 'c.example'];
      s.sample(hosts: small, ips: const [], count: 3);
      expect(s.sample(hosts: small, ips: const [], count: 3).length, 3);
    });

    test('geoip вторичен: IP только из успешных или при нехватке хостов', () {
      final s = ReachabilitySampler(random: Random(5));
      final noPref = s.sample(hosts: hosts, ips: const ['1.1.1.1'], count: 3);
      expect(noPref.where((t) => t.isIp), isEmpty);

      final pref = s.sample(
          hosts: hosts,
          ips: const ['1.1.1.1', '2.2.2.2'],
          count: 3,
          preferredIps: const {'2.2.2.2'});
      expect(pref.where((t) => t.isIp).map((t) => t.host), ['2.2.2.2']);
      expect(pref.length, 3);

      final fewHosts = s.sample(
          hosts: const ['only.example'], ips: const ['1.1.1.1'], count: 3);
      expect(fewHosts.where((t) => t.isIp).length, 1);
    });
  });

  group('verdict', () {
    const t = ReachabilityTarget('x.example');

    test('хотя бы один из N — успех', () {
      expect(
          overallVerdict(const [
            TargetResult(t, reachable: false),
            TargetResult(t, reachable: true),
            TargetResult(t, reachable: false),
          ]),
          isTrue);
    });

    test('ни один — провал; пустая выборка — не вердикт', () {
      expect(
          overallVerdict(const [
            TargetResult(t, reachable: false),
            TargetResult(t, reachable: false),
          ]),
          isFalse);
      expect(overallVerdict(const []), isNull);
    });

    test('любой HTTP-статус — доступность, как P13', () {
      expect(isReachableResponse(status: 200, error: ''), isTrue);
      expect(isReachableResponse(status: 403, error: ''), isTrue);
      expect(isReachableResponse(status: 503, error: ''), isTrue);
    });

    test('ошибка сертификата — handshake состоялся; таймаут/сброс — нет', () {
      expect(
          isReachableResponse(
              status: 0,
              error: 'tls: failed to verify certificate: x509: certificate is valid for a, not b'),
          isTrue);
      expect(isReachableResponse(status: 0, error: 'context deadline exceeded'),
          isFalse);
      expect(
          isReachableResponse(status: 0, error: 'read: connection reset by peer'),
          isFalse);
      expect(isReachableResponse(status: 0, error: 'EOF'), isFalse);
    });
  });

  group('ReachabilityActionGate', () {
    final t0 = DateTime(2026, 11, 5, 12);
    const interval = Duration(minutes: 15);

    test('не чаще одного действия за интервал', () {
      final g = ReachabilityActionGate();
      bool allow(DateTime now) => g.allow(
          action: ReachabilityAction.resetNetwork,
          now: now,
          interval: interval,
          checkEpoch: g.epoch,
          tunnelConnected: true);
      expect(allow(t0), isTrue);
      g.markActed(t0);
      expect(allow(t0.add(const Duration(minutes: 14))), isFalse);
      expect(allow(t0.add(interval)), isTrue);
    });

    test('явный Stop во время проверки отменяет реакцию', () {
      final g = ReachabilityActionGate();
      final epoch = g.epoch; // проверка стартовала
      g.onExplicitStop(); // пользователь нажал Stop
      expect(
          g.allow(
              action: ReachabilityAction.reconnect,
              now: t0,
              interval: interval,
              checkEpoch: epoch,
              tunnelConnected: true),
          isFalse);
    });

    test('туннель не Connected — Reconnect не воскрешает его', () {
      final g = ReachabilityActionGate();
      expect(
          g.allow(
              action: ReachabilityAction.reconnect,
              now: t0,
              interval: interval,
              checkEpoch: g.epoch,
              tunnelConnected: false),
          isFalse);
    });

    test('notify ограничителем не режется', () {
      final g = ReachabilityActionGate()..markActed(t0);
      expect(
          g.allow(
              action: ReachabilityAction.notify,
              now: t0,
              interval: interval,
              checkEpoch: g.epoch,
              tunnelConnected: true),
          isTrue);
    });
  });

  test('ReachabilityAction.parse: неизвестное → notify', () {
    expect(ReachabilityAction.parse('reconnect'), ReachabilityAction.reconnect);
    expect(ReachabilityAction.parse('resetNetwork'),
        ReachabilityAction.resetNetwork);
    expect(ReachabilityAction.parse('bogus'), ReachabilityAction.notify);
    expect(ReachabilityAction.parse(null), ReachabilityAction.notify);
  });
}
