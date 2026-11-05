import '../../config/consts.dart' show kDirectOutboundTag;
import '../../vpn/cc_channel.dart';
import '../reachability/reachability_logic.dart' show isReachableResponse;
import '../subscription/user_agent.dart';
import '../url_mask.dart';

/// §724 — итог проверки хоста через выходы ядра.
enum ExitVerdict { direct, proxyOnly, none }

class ExitCheck {
  const ExitCheck(
    this.verdict, {
    this.directDetail = '',
    this.proxyDetail = '',
  });

  final ExitVerdict verdict;
  final String directDetail;
  final String proxyDetail;
}

/// Запрос через live-ядро по тегу: (status, error). Шов для тестов.
typedef ExitProbeFn =
    Future<(int, String)> Function(String tag, String url, int timeoutMs);

Future<(int, String)> _coreProbe(String tag, String url, int timeoutMs) async {
  final r = await CcChannel.instance.getUrlViaOutbound(
    tag,
    link: url,
    timeoutMs: timeoutMs,
    maxBytes: 1024,
    userAgent: resolveAppUserAgent(),
  );
  return (r.status, r.error);
}

/// §724 — проверить [host] через `direct-out` и через [proxyTag]
/// (`route.final` работающего конфига) — тот же путь P13, что у проверки
/// доступности 721: selector не трогается, сокет — из ядра, а не из
/// процесса приложения. Успех — любой HTTP-ответ или TLS-ошибка сертификата
/// (сервер ответил) — [isReachableResponse].
///
/// [proxyTag] == `direct-out` или null — прокси проверять нечем: тогда
/// «только через прокси» невозможен, итог — direct или none.
Future<ExitCheck> checkExits(
  String host, {
  required String? proxyTag,
  int timeoutMs = 5000,
  ExitProbeFn? probe,
}) async {
  final p = probe ?? _coreProbe;
  final url = 'https://$host/';

  Future<(bool, String)> one(String tag) async {
    try {
      final (status, error) = await p(tag, url, timeoutMs);
      final ok = isReachableResponse(status: status, error: error);
      return (ok, error.isEmpty ? '$status' : _short(error));
    } catch (e) {
      return (false, _short('$e'));
    }
  }

  final hasProxy = proxyTag != null && proxyTag != kDirectOutboundTag;
  final results = await Future.wait([
    one(kDirectOutboundTag),
    if (hasProxy) one(proxyTag),
  ]);
  final (directOk, directDetail) = results[0];
  final (proxyOk, proxyDetail) = hasProxy ? results[1] : (false, '');
  final verdict = directOk
      ? ExitVerdict.direct
      : proxyOk
      ? ExitVerdict.proxyOnly
      : ExitVerdict.none;
  return ExitCheck(
    verdict,
    directDetail: directDetail,
    proxyDetail: proxyDetail,
  );
}

/// Ошибки ядра несут адрес сервера — маскируем, как 721.
String _short(String e) {
  final m = maskNetworkAddresses(e);
  return m.length > 80 ? '${m.substring(0, 80)}…' : m;
}
