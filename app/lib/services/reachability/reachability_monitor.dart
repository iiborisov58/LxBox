import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../vpn/box_vpn_client.dart';
import '../../vpn/cc_channel.dart';
import '../app_log.dart';
import '../automation/event_emitter.dart';
import '../l10n/locale_controller.dart';
import '../rule_set_auto_updater.dart';
import '../rule_set_downloader.dart';
import '../settings_storage.dart';
import '../subscription/user_agent.dart';
import '../url_mask.dart';
import 'reachability_logic.dart';
import 'srs_reader.dart';

/// §721 — настройки проверки доступности заблокированных ресурсов.
class ReachabilitySettings {
  const ReachabilitySettings({
    this.enabled = false,
    this.intervalMinutes = 15,
    this.sampleSize = 3,
    this.timeoutSeconds = 5,
    this.skipWhenScreenOff = true,
    this.onFail = ReachabilityAction.notify,
  });

  static const intervals = [5, 15, 30, 60];
  static const sampleSizes = [3, 4, 5];
  static const timeouts = [3, 5, 10];

  final bool enabled;
  final int intervalMinutes;
  final int sampleSize;
  final int timeoutSeconds;
  final bool skipWhenScreenOff;
  final ReachabilityAction onFail;

  Duration get interval => Duration(minutes: intervalMinutes);

  static const _kEnabled = 'reachability_enabled';
  static const _kInterval = 'reachability_interval_min';
  static const _kSample = 'reachability_sample';
  static const _kTimeout = 'reachability_timeout_s';
  static const _kScreen = 'reachability_skip_screen_off';
  static const _kOnFail = 'reachability_on_fail';

  static int _pick(String raw, List<int> allowed, int fallback) {
    final v = int.tryParse(raw);
    return v != null && allowed.contains(v) ? v : fallback;
  }

  static Future<ReachabilitySettings> load() async {
    const d = ReachabilitySettings();
    return ReachabilitySettings(
      enabled: (await SettingsStorage.getVar(_kEnabled, 'false')) == 'true',
      intervalMinutes: _pick(await SettingsStorage.getVar(_kInterval, ''),
          intervals, d.intervalMinutes),
      sampleSize: _pick(await SettingsStorage.getVar(_kSample, ''),
          sampleSizes, d.sampleSize),
      timeoutSeconds: _pick(await SettingsStorage.getVar(_kTimeout, ''),
          timeouts, d.timeoutSeconds),
      skipWhenScreenOff:
          (await SettingsStorage.getVar(_kScreen, 'true')) == 'true',
      onFail: ReachabilityAction.parse(
          await SettingsStorage.getVar(_kOnFail, 'notify')),
    );
  }

  Future<void> save() async {
    await SettingsStorage.setVar(_kEnabled, '$enabled', flush: false);
    await SettingsStorage.setVar(_kInterval, '$intervalMinutes', flush: false);
    await SettingsStorage.setVar(_kSample, '$sampleSize', flush: false);
    await SettingsStorage.setVar(_kTimeout, '$timeoutSeconds', flush: false);
    await SettingsStorage.setVar(_kScreen, '$skipWhenScreenOff', flush: false);
    await SettingsStorage.setVar(_kOnFail, onFail.name);
  }

  ReachabilitySettings copyWith({
    bool? enabled,
    int? intervalMinutes,
    int? sampleSize,
    int? timeoutSeconds,
    bool? skipWhenScreenOff,
    ReachabilityAction? onFail,
  }) =>
      ReachabilitySettings(
        enabled: enabled ?? this.enabled,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        sampleSize: sampleSize ?? this.sampleSize,
        timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
        skipWhenScreenOff: skipWhenScreenOff ?? this.skipWhenScreenOff,
        onFail: onFail ?? this.onFail,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'interval_min': intervalMinutes,
        'sample': sampleSize,
        'timeout_s': timeoutSeconds,
        'skip_screen_off': skipWhenScreenOff,
        'on_fail': onFail.name,
      };

  /// Debug API `PUT /settings/reachability`: частичное обновление, значения
  /// вне допустимых наборов — [FormatException].
  ReachabilitySettings mergeJson(Map<String, dynamic> j) {
    int? intIn(String key, List<int> allowed) {
      if (!j.containsKey(key)) return null;
      final v = j[key];
      if (v is! int || !allowed.contains(v)) {
        throw FormatException('"$key" must be one of $allowed');
      }
      return v;
    }

    bool? boolIn(String key) {
      if (!j.containsKey(key)) return null;
      final v = j[key];
      if (v is! bool) throw FormatException('"$key" must be bool');
      return v;
    }

    ReachabilityAction? action;
    if (j.containsKey('on_fail')) {
      final v = j['on_fail'];
      action = ReachabilityAction.values
          .where((a) => a.name == v)
          .firstOrNull;
      if (action == null) {
        throw const FormatException(
            '"on_fail" must be notify|resetNetwork|reconnect');
      }
    }
    return copyWith(
      enabled: boolIn('enabled'),
      intervalMinutes: intIn('interval_min', intervals),
      sampleSize: intIn('sample', sampleSizes),
      timeoutSeconds: intIn('timeout_s', timeouts),
      skipWhenScreenOff: boolIn('skip_screen_off'),
      onFail: action,
    );
  }
}

/// §721 — итог последней проверки.
class ReachabilityStatus {
  const ReachabilityStatus({
    this.at,
    this.ok,
    this.checked = 0,
    this.reachable = 0,
    this.action,
    this.skipped,
  });

  final DateTime? at;

  /// null — проверки ещё не было или выборка пуста.
  final bool? ok;
  final int checked;
  final int reachable;

  /// Выполненная реакция на провал (wire-имя), если была.
  final String? action;

  /// Причина пропуска последнего тика (wire): `screen_off`, `no_candidates`,
  /// `no_route` — или null.
  final String? skipped;

  Map<String, Object?> toJson() => {
        'at': at?.toUtc().toIso8601String(),
        'ok': ok,
        'checked': checked,
        'reachable': reachable,
        'action': action,
        'skipped': skipped,
      };
}

/// Связь с HomeController: состояние туннеля и реакции.
class ReachabilityHost {
  const ReachabilityHost({
    required this.tunnelConnected,
    required this.routeFinalTag,
    required this.resetNetwork,
    required this.reconnect,
  });

  final bool Function() tunnelConnected;

  /// Тег `route.final` работающего конфига: туда уходит заблокированное.
  final String? Function() routeFinalTag;
  final Future<bool> Function() resetNetwork;
  final Future<void> Function() reconnect;
}

/// §721 — периодическая проверка, что через активный туннель открывается
/// хотя бы один ресурс из списков блокировок.
///
/// **Opt-in, по умолчанию выключено.** Отличие от отвергнутого health-watchdog
/// (§042F, §088): не постоянный пробник, а редкий таймер (5–60 мин), который
/// живёт только при Connected и (по умолчанию) молчит при выключенном экране.
///
/// Запрос идёт через live-ядро по тегу (`getUrlViaOutbound`, механизм P13
/// 009): процесс приложения сокетов не открывает, selector не трогается.
class ReachabilityMonitor extends ChangeNotifier {
  ReachabilityMonitor._();
  static final ReachabilityMonitor I = ReachabilityMonitor._();

  static const geositeUrl =
      'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs';
  static const geoipUrl =
      'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked-community.srs';

  /// Префикс кэша `rule_sets/`: [RuleSetDownloader.pruneOrphans] его не трогает.
  static const cachePrefix = kReachabilityCachePrefix;
  static const geositeCacheId = '${cachePrefix}geosite-ru-blocked';
  static const geoipCacheId = '${cachePrefix}geoip-ru-blocked-community';

  /// TTL наборов — как у пресетов runetfreedom в шаблоне.
  static const ruleSetTtlHours = 168;

  /// Первая проверка — не сразу после connected: туннелю дать устояться.
  static const firstCheckDelay = Duration(seconds: 60);

  ReachabilityHost? _host;
  ReachabilitySettings _settings = const ReachabilitySettings();
  ReachabilityStatus _status = const ReachabilityStatus();
  final ReachabilitySampler _sampler = ReachabilitySampler();
  final ReachabilityActionGate _gate = ReachabilityActionGate();

  Timer? _timer;
  bool _running = false;
  bool _failStreak = false;
  ({List<String> hosts, List<String> ips})? _candidates;
  String? _candidatesStamp;
  final Set<String> _goodIps = {};
  bool _candidatesPinned = false;

  /// Тест-шов: подмена вызова ядра и экрана.
  @visibleForTesting
  Future<CcGetUrlResult> Function(String tag, String url, int timeoutMs)?
      probeOverride;

  @visibleForTesting
  Future<bool> Function()? screenOverride;

  ReachabilitySettings get settings => _settings;
  ReachabilityStatus get status => _status;
  bool get running => _running;

  void bind(ReachabilityHost host) => _host = host;

  /// §724 — привязанный хост (туннель, `route.final`) для помощника доменов.
  ReachabilityHost? get host => _host;

  /// Старт приложения: подтянуть настройки.
  Future<void> init() async {
    _settings = await ReachabilitySettings.load();
    notifyListeners();
  }

  Future<void> updateSettings(ReachabilitySettings next) async {
    _settings = next;
    await next.save();
    notifyListeners();
    _reschedule(const Duration(seconds: 5));
  }

  /// Туннель поднялся.
  void onTunnelConnected() => _reschedule(firstCheckDelay);

  /// Туннель ушёл в down (явный Stop, ошибка, revoke): проверки и любая
  /// запланированная реакция отменяются.
  void onTunnelDown() {
    _timer?.cancel();
    _timer = null;
    _gate.onExplicitStop();
  }

  void _reschedule(Duration delay) {
    _timer?.cancel();
    _timer = null;
    final host = _host;
    if (!_settings.enabled || host == null || !host.tunnelConnected()) return;
    _timer = Timer(delay, () => unawaited(_tick()));
  }

  Future<void> _tick() async {
    _timer = null;
    final host = _host;
    if (!_settings.enabled || host == null || !host.tunnelConnected()) return;
    try {
      if (_settings.skipWhenScreenOff &&
          !await (screenOverride ?? BoxVpnClient.I.isScreenInteractive)()) {
        _setSkipped('screen_off');
        return;
      }
      await runCheck();
    } catch (e) {
      AppLog.I.warning('[reachability] check error: ${maskNetworkAddresses('$e')}');
    } finally {
      _reschedule(_settings.interval);
    }
  }

  void _setSkipped(String reason) {
    AppLog.I.debug('[reachability] skipped: $reason');
    _status = ReachabilityStatus(
      at: _status.at,
      ok: _status.ok,
      checked: _status.checked,
      reachable: _status.reachable,
      action: _status.action,
      skipped: reason,
    );
    notifyListeners();
  }

  /// Одна проверка. Зовётся таймером и Debug API (`/action/reachability-check`).
  /// Бросает [StateError], если туннель не Connected.
  Future<ReachabilityStatus> runCheck() async {
    final host = _host;
    if (host == null || !host.tunnelConnected()) {
      throw StateError('tunnel not connected');
    }
    if (_running) return _status;
    _running = true;
    notifyListeners();
    final epoch = _gate.epoch;
    try {
      final tag = host.routeFinalTag();
      if (tag == null || tag.isEmpty || tag == 'direct-out') {
        _setSkipped('no_route');
        return _status;
      }
      final cands = await _loadCandidates();
      if (cands == null || (cands.hosts.isEmpty && cands.ips.isEmpty)) {
        _setSkipped('no_candidates');
        return _status;
      }
      final targets = _sampler.sample(
        hosts: cands.hosts,
        ips: cands.ips,
        count: _settings.sampleSize,
        preferredIps: _goodIps,
      );
      final timeoutMs = _settings.timeoutSeconds * 1000;
      final results = await Future.wait([
        for (final t in targets) _probe(tag, t, timeoutMs),
      ]);
      // Туннель упал или был остановлен, пока шла проверка — итог не значим.
      if (epoch != _gate.epoch || !host.tunnelConnected()) return _status;
      for (final r in results) {
        if (r.target.isIp && r.reachable) _goodIps.add(r.target.host);
      }
      final verdict = overallVerdict(results);
      final reachable = results.where((r) => r.reachable).length;
      AppLog.I.info('[reachability] ${verdict == true ? 'ok' : 'FAIL'} '
          '$reachable/${results.length}: '
          '${results.map((r) => '${r.target.host}=${r.reachable ? 'ok' : r.detail}').join(', ')}');
      String? acted;
      if (verdict == false) {
        acted = await _react(host, epoch, results.length);
      } else if (verdict == true && _failStreak) {
        _failStreak = false;
        AutomationEventEmitter.I
            .emitReachabilityRestored(results.length, reachable);
        unawaited(BoxVpnClient.I.cancelReachabilityAlert());
      }
      _status = ReachabilityStatus(
        at: DateTime.now(),
        ok: verdict,
        checked: results.length,
        reachable: reachable,
        action: acted,
      );
      return _status;
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<TargetResult> _probe(
      String tag, ReachabilityTarget t, int timeoutMs) async {
    try {
      final override = probeOverride;
      final r = override != null
          ? await override(tag, t.url, timeoutMs)
          : await CcChannel.instance.getUrlViaOutbound(
              tag,
              link: t.url,
              timeoutMs: timeoutMs,
              maxBytes: 1024,
              userAgent: resolveAppUserAgent(),
            );
      final ok = isReachableResponse(status: r.status, error: r.error);
      final detail = r.error.isEmpty ? '${r.status}' : _short(r.error);
      return TargetResult(t, reachable: ok, detail: detail);
    } catch (e) {
      return TargetResult(t, reachable: false, detail: _short('$e'));
    }
  }

  /// Ошибки ядра несут адрес сервера (`dial tcp <ip>:<port>`) — маскируем
  /// (P14 014) и режем до разумной длины.
  static String _short(String e) {
    final m = maskNetworkAddresses(e);
    return m.length > 80 ? '${m.substring(0, 80)}…' : m;
  }

  Future<String?> _react(ReachabilityHost host, int epoch, int checked) async {
    final action = _settings.onFail;
    final firstInStreak = !_failStreak;
    _failStreak = true;
    String? acted;
    final now = DateTime.now();
    if (_gate.allow(
      action: action,
      now: now,
      interval: _settings.interval,
      checkEpoch: epoch,
      tunnelConnected: host.tunnelConnected(),
    )) {
      switch (action) {
        case ReachabilityAction.notify:
          if (firstInStreak) {
            unawaited(BoxVpnClient.I.showReachabilityAlert(
              getLocalText.s("Blocked sites are not opening"),
              getLocalText.s(
                  "The tunnel is connected, but none of the checked blocked sites responded through it."),
            ));
            acted = action.name;
          }
        case ReachabilityAction.resetNetwork:
          _gate.markActed(now);
          await host.resetNetwork();
          acted = action.name;
        case ReachabilityAction.reconnect:
          _gate.markActed(now);
          await host.reconnect();
          acted = action.name;
      }
    } else {
      AppLog.I.info('[reachability] ${action.name} suppressed (rate limit or stop)');
    }
    AutomationEventEmitter.I.emitReachabilityFailed(checked, acted ?? 'none');
    return acted;
  }

  // ─── Кандидаты ──────────────────────────────────────────────────────────────

  Future<({List<String> hosts, List<String> ips})?> _loadCandidates() async {
    if (_candidatesPinned) return _candidates;
    await _refreshRuleSet(geositeCacheId, geositeUrl);
    await _refreshRuleSet(geoipCacheId, geoipUrl);
    final sitePath = await RuleSetDownloader.cachedPath(geositeCacheId);
    final ipPath = await RuleSetDownloader.cachedPath(geoipCacheId);
    if (sitePath == null && ipPath == null) return _candidates;
    final stamp = '${await _fileStamp(sitePath)}|${await _fileStamp(ipPath)}';
    if (_candidates != null && _candidatesStamp == stamp) return _candidates;

    // Кэш разбора на диске: 500 КБ `.srs` не разбираем на каждой проверке и
    // на каждом старте процесса.
    final cacheFile = await _candidatesFile();
    try {
      if (await cacheFile.exists()) {
        final j = jsonDecode(await cacheFile.readAsString());
        if (j is Map && j['stamp'] == stamp) {
          _candidates = (
            hosts: (j['hosts'] as List).cast<String>(),
            ips: (j['ips'] as List).cast<String>(),
          );
          _candidatesStamp = stamp;
          return _candidates;
        }
      }
    } catch (_) {}

    final site = sitePath == null ? null : await File(sitePath).readAsBytes();
    final ip = ipPath == null ? null : await File(ipPath).readAsBytes();
    try {
      final c = await Isolate.run(() => _parseCandidates(site, ip));
      _candidates = c;
      _candidatesStamp = stamp;
      AppLog.I.info('[reachability] candidates: ${c.hosts.length} hosts, '
          '${c.ips.length} ips');
      unawaited(cacheFile
          .writeAsString(jsonEncode({'stamp': stamp, 'hosts': c.hosts, 'ips': c.ips}))
          .catchError((_) => cacheFile));
    } catch (e) {
      AppLog.I.warning('[reachability] rule-set parse failed: $e');
    }
    return _candidates;
  }

  static ({List<String> hosts, List<String> ips}) _parseCandidates(
      Uint8List? site, Uint8List? ip) {
    SrsDump? s;
    SrsDump? i;
    if (site != null) s = readSrs(site);
    if (ip != null) i = readSrs(ip);
    return buildCandidates(s, i);
  }

  static Future<String> _fileStamp(String? path) async {
    if (path == null) return '-';
    try {
      final st = await File(path).stat();
      return '${st.size}:${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return '-';
    }
  }

  static Future<File> _candidatesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/reachability_candidates.json');
  }

  /// Скачивание/обновление набора существующим механизмом (условный GET,
  /// TTL как у пресетов). Провал — работаем со старым файлом.
  static Future<void> _refreshRuleSet(String cacheId, String url) async {
    final meta = await RuleSetDownloader.readMeta(cacheId);
    final cached = await RuleSetDownloader.isCached(cacheId);
    if (cached &&
        !RuleSetAutoUpdater.shouldUpdatePure(
            meta: meta, intervalHours: ruleSetTtlHours, now: DateTime.now())) {
      return;
    }
    final r = await RuleSetDownloader.fetch(cacheId, url, conditional: cached);
    if (r.outcome == DownloadOutcome.failed) {
      AppLog.I.warning('[reachability] download $cacheId failed');
    }
  }

  @visibleForTesting
  void debugReset() {
    _timer?.cancel();
    _timer = null;
    _host = null;
    _settings = const ReachabilitySettings();
    _status = const ReachabilityStatus();
    _running = false;
    _failStreak = false;
    _candidates = null;
    _candidatesStamp = null;
    _candidatesPinned = false;
    _goodIps.clear();
    probeOverride = null;
    screenOverride = null;
  }

  @visibleForTesting
  void debugSetSettings(ReachabilitySettings s) => _settings = s;

  @visibleForTesting
  void debugSetCandidates(List<String> hosts, List<String> ips) {
    _candidates = (hosts: hosts, ips: ips);
    _candidatesPinned = true;
  }
}
