import 'dart:math';

import 'srs_reader.dart';

/// §721 — реакция на провал проверки доступности.
enum ReachabilityAction {
  /// Только уведомить (по умолчанию).
  notify,

  /// `resetNetwork` ядра: закрыть соединения, сбросить DNS-кэш.
  resetNetwork,

  /// Переподключить туннель.
  reconnect;

  /// Wire-значение (настройки, Debug API, события) — имя enum'а.
  static ReachabilityAction parse(String? v) => switch (v) {
        'resetNetwork' => resetNetwork,
        'reconnect' => reconnect,
        _ => notify,
      };
}

/// §721 — кандидат на проверку: хост из geosite или адрес из geoip.
class ReachabilityTarget {
  const ReachabilityTarget(this.host, {this.isIp = false});

  final String host;
  final bool isIp;

  /// Адрес запроса через ядро. HTTPS и для IP: заблокированное режут по SNI
  /// или по адресу, а несовпавший у IP сертификат — всё равно ответ сервера.
  String get url => 'https://$host/';

  @override
  bool operator ==(Object other) =>
      other is ReachabilityTarget && other.host == host && other.isIp == isIp;

  @override
  int get hashCode => Object.hash(host, isIp);
}

/// Максимальный размер IPv4-диапазона, адрес из которого берём кандидатом.
/// Подсеть крупнее — случайный адрес в ней почти наверняка «молчит» и дал бы
/// ложный провал. 4 адреса — точечные записи вроде `/32`…`/30`.
const int kMaxIpRangeSize = 4;

/// §721 — хосты-кандидаты из разобранных rule-set'ов. Чистая функция.
///
/// - `domain` и `domain_suffix` годятся как хосты (суффикс — сам себе хост);
///   `domain_keyword` и `domain_regex` отбрасываются: из них нельзя честно
///   получить имя.
/// - Отбрасываются имена без точки (`ru`, `com` — зоны, не сайты), с
///   ведущей точкой, с маской `*` и не-ASCII (в `.srs` — punycode).
/// - geoip — вторичный источник: только IPv4-диапазоны размером не больше
///   [kMaxIpRangeSize], берётся первый адрес.
({List<String> hosts, List<String> ips}) buildCandidates(
  SrsDump? geosite,
  SrsDump? geoip,
) {
  final hosts = <String>{};
  if (geosite != null) {
    for (final d in [...geosite.domains, ...geosite.domainSuffixes]) {
      final h = d.trim().toLowerCase();
      if (isUsableHost(h)) hosts.add(h);
    }
  }
  final ips = <String>{};
  if (geoip != null) {
    for (final r in geoip.ipRanges) {
      final size = r.sizeV4;
      if (size == null || size < 1 || size > kMaxIpRangeSize) continue;
      ips.add(r.fromText);
    }
  }
  return (hosts: hosts.toList()..sort(), ips: ips.toList()..sort());
}

final _hostRe = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');

bool isUsableHost(String h) =>
    h.length <= 253 && h.contains('.') && _hostRe.hasMatch(h);

/// §721 — выборка N целей за проверку с ротацией.
///
/// Цели прошлой проверки в новую не попадают (если кандидатов хватает), так
/// что подряд одни и те же хосты не повторяются. Адреса из geoip идут
/// вторичным источником: в выборку попадает не больше одного, и только если
/// есть [preferredIps] — адреса, на которых проверка уже была успешной, — или
/// хостов меньше N.
class ReachabilitySampler {
  ReachabilitySampler({Random? random}) : _random = random ?? Random();

  final Random _random;
  Set<ReachabilityTarget> _previous = const {};

  List<ReachabilityTarget> sample({
    required List<String> hosts,
    required List<String> ips,
    required int count,
    Set<String> preferredIps = const {},
  }) {
    if (count <= 0) return const [];
    final out = <ReachabilityTarget>[];

    List<T> pick<T>(List<T> from, int n, bool Function(T) fresh) {
      final pool = from.where(fresh).toList();
      final source = pool.length >= n ? pool : from;
      final copy = List<T>.of(source);
      final result = <T>[];
      while (result.length < n && copy.isNotEmpty) {
        result.add(copy.removeAt(_random.nextInt(copy.length)));
      }
      return result;
    }

    final ipPool = preferredIps.isNotEmpty
        ? ips.where(preferredIps.contains).toList()
        : const <String>[];
    final wantIp = ipPool.isNotEmpty || (hosts.length < count && ips.isNotEmpty);
    final hostCount = wantIp ? count - 1 : count;

    for (final h in pick<String>(hosts, hostCount,
        (h) => !_previous.contains(ReachabilityTarget(h)))) {
      out.add(ReachabilityTarget(h));
    }
    if (wantIp) {
      final from = ipPool.isNotEmpty ? ipPool : ips;
      final need = count - out.length;
      for (final ip in pick<String>(from, need,
          (ip) => !_previous.contains(ReachabilityTarget(ip, isIp: true)))) {
        out.add(ReachabilityTarget(ip, isIp: true));
      }
    }
    _previous = out.toSet();
    return out;
  }
}

/// Результат одной цели.
class TargetResult {
  const TargetResult(this.target, {required this.reachable, this.detail = ''});

  final ReachabilityTarget target;
  final bool reachable;

  /// Статус или текст ошибки (для журнала; без адресов серверов).
  final String detail;
}

/// §721 — вердикт по ответу ядра: доступность — любой HTTP-статус (как P13)
/// или ошибка, которая доказывает состоявшийся TLS handshake (сертификат не
/// сошёлся — сервер ответил). Таймаут, сброс, EOF — недоступность.
bool isReachableResponse({required int status, required String error}) {
  if (error.isEmpty) return status > 0;
  final e = error.toLowerCase();
  return e.contains('x509') ||
      e.contains('certificate') ||
      e.contains('tls: unrecognized name');
}

/// §721 — правило «хотя бы один из N». Пустая выборка — не провал.
bool? overallVerdict(List<TargetResult> results) {
  if (results.isEmpty) return null;
  return results.any((r) => r.reachable);
}

/// §721 — ограничитель реакций: не чаще одного действия за интервал, и
/// явный Stop пользователя отменяет реакцию (P12 010: явный Stop не
/// воскрешается).
class ReachabilityActionGate {
  DateTime? _lastActionAt;
  int _stopEpoch = 0;

  /// Номер «эпохи» на момент старта проверки — сверяется перед действием.
  int get epoch => _stopEpoch;

  /// Явный Stop пользователя (или любой уход туннеля в down).
  void onExplicitStop() => _stopEpoch++;

  /// Можно ли выполнить [action] сейчас. `notify` не ограничивается: это не
  /// вмешательство в туннель (повтор уведомления гасит сам вызывающий).
  bool allow({
    required ReachabilityAction action,
    required DateTime now,
    required Duration interval,
    required int checkEpoch,
    required bool tunnelConnected,
  }) {
    if (action == ReachabilityAction.notify) return true;
    if (checkEpoch != _stopEpoch || !tunnelConnected) return false;
    final last = _lastActionAt;
    if (last != null && now.difference(last) < interval) return false;
    return true;
  }

  void markActed(DateTime now) => _lastActionAt = now;
}
