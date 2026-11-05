import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/automation/event_emitter.dart';
import 'package:lxbox/services/reachability/reachability_logic.dart';
import 'package:lxbox/services/reachability/reachability_monitor.dart';
import 'package:lxbox/vpn/cc_channel.dart';

CcGetUrlResult _res({int status = 0, String error = ''}) => CcGetUrlResult(
      status: status,
      content: '',
      truncated: false,
      contentType: '',
      remoteAddr: '',
      elapsedMs: 1,
      error: error,
    );

/// §721 — оркестратор: итог «хотя бы один из N», реакция на провал, отмена
/// реакции явным Stop, события Health без адресов.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final m = ReachabilityMonitor.I;
  late bool connected;
  late int resets;
  late int reconnects;
  late List<(String, Map<String, Object?>)> events;

  setUp(() {
    m.debugReset();
    connected = true;
    resets = 0;
    reconnects = 0;
    events = [];
    AutomationEventEmitter.I.debugConfigureForTest(
        health: true, onSend: (a, e) => events.add((a, e)));
    m.bind(ReachabilityHost(
      tunnelConnected: () => connected,
      routeFinalTag: () => 'proxy-out',
      resetNetwork: () async {
        resets++;
        return true;
      },
      reconnect: () async => reconnects++,
    ));
    m.debugSetCandidates(
        [for (var i = 0; i < 10; i++) 'h$i.example'], const []);
  });

  tearDown(m.debugReset);

  test('туннель не Connected — проверка не идёт', () async {
    connected = false;
    expect(m.runCheck(), throwsStateError);
  });

  test('хотя бы один ответил — успех, реакции нет', () async {
    var n = 0;
    m.probeOverride = (tag, url, t) async {
      expect(tag, 'proxy-out');
      return n++ == 0 ? _res(status: 403) : _res(error: 'i/o timeout');
    };
    final st = await m.runCheck();
    expect(st.ok, isTrue);
    expect(st.reachable, 1);
    expect(resets, 0);
    expect(events, isEmpty);
  });

  test('провал → resetNetwork один раз за интервал, событие без хостов', () async {
    m.debugSetSettings(const ReachabilitySettings(
        enabled: true, onFail: ReachabilityAction.resetNetwork));
    m.probeOverride =
        (tag, url, t) async => _res(error: 'dial tcp 203.0.113.7:443: timeout');
    final st = await m.runCheck();
    expect(st.ok, isFalse);
    expect(st.action, 'resetNetwork');
    expect(resets, 1);
    await m.runCheck();
    expect(resets, 1, reason: 'второе действие в пределах интервала');
    expect(events.first.$1, 'REACHABILITY_FAILED');
    expect(events.first.$2, {'checked': 3, 'action': 'resetNetwork'});
    expect(events.last.$2['action'], 'none');
  });

  test('явный Stop посреди проверки — Reconnect не выполняется', () async {
    m.debugSetSettings(const ReachabilitySettings(
        enabled: true, onFail: ReachabilityAction.reconnect));
    final gate = Completer<void>();
    m.probeOverride = (tag, url, t) async {
      await gate.future;
      return _res(error: 'EOF');
    };
    final run = m.runCheck();
    connected = false;
    m.onTunnelDown();
    gate.complete();
    await run;
    expect(reconnects, 0);
    expect(events, isEmpty);
  });

  test('успех после провала — REACHABILITY_RESTORED', () async {
    m.probeOverride = (tag, url, t) async => _res(error: 'EOF');
    await m.runCheck();
    m.probeOverride = (tag, url, t) async => _res(status: 200);
    await m.runCheck();
    expect(events.map((e) => e.$1),
        ['REACHABILITY_FAILED', 'REACHABILITY_RESTORED']);
    expect(events.last.$2, {'checked': 3, 'reachable': 3});
  });

  test('route.final = direct-out — пропуск, не провал', () async {
    m.bind(ReachabilityHost(
      tunnelConnected: () => true,
      routeFinalTag: () => 'direct-out',
      resetNetwork: () async => true,
      reconnect: () async {},
    ));
    final st = await m.runCheck();
    expect(st.skipped, 'no_route');
    expect(st.ok, isNull);
  });
}
