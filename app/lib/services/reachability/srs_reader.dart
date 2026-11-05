import 'dart:convert';
import 'dart:io' show InternetAddress, zlib;
import 'dart:typed_data';

/// §721 — что достали из бинарного rule-set'а sing-box (`.srs`).
///
/// Только те поля, что нужны проверке доступности: домены, суффиксы,
/// keyword/regex (считаются, чтобы отбросить осознанно) и IP-диапазоны.
/// Остальные элементы правил (порты, процессы, Wi-Fi…) разбираются и
/// пропускаются.
class SrsDump {
  SrsDump();

  final List<String> domains = [];
  final List<String> domainSuffixes = [];
  final List<String> domainKeywords = [];
  final List<String> domainRegexes = [];

  /// Диапазоны `ip_cidr` (не `source_ip_cidr`): пары адресов from/to по 4 или
  /// 16 байт, как их хранит ядро.
  final List<SrsIpRange> ipRanges = [];
}

/// Диапазон адресов `[from, to]` включительно.
class SrsIpRange {
  const SrsIpRange(this.from, this.to);

  final Uint8List from;
  final Uint8List to;

  bool get isV4 => from.length == 4;

  /// Число адресов в диапазоне для IPv4; для IPv6 — null (не нужен).
  int? get sizeV4 {
    if (!isV4) return null;
    int v(Uint8List b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    return v(to) - v(from) + 1;
  }

  String get fromText => _ipText(from);
  String get toText => _ipText(to);

  static String _ipText(Uint8List b) {
    if (b.length == 4) return b.join('.');
    final parts = <String>[];
    for (var i = 0; i < 16; i += 2) {
      parts.add(((b[i] << 8) | b[i + 1]).toRadixString(16));
    }
    return InternetAddress(parts.join(':')).address;
  }
}

/// Ошибка формата `.srs`.
class SrsFormatException implements Exception {
  const SrsFormatException(this.message);
  final String message;
  @override
  String toString() => 'SrsFormatException: $message';
}

/// §721 — разбор бинарного rule-set'а sing-box без ядра.
///
/// Формат — `common/srs/binary.go` ядра: `"SRS"` + версия (1 байт) +
/// zlib-поток: uvarint число правил, далее правила. Домены (`domain` и
/// `domain_suffix` вместе) лежат succinct-trie'ем (`common/domain/set.go` в
/// sing): ключи — перевёрнутые домены, суффикс помечен префиксом `\r`
/// (с точкой — legacy-форма v1) или `\n` (v2+). Разворот ключей — как
/// `Matcher.Dump()` ядра.
///
/// Чистая функция: ни файлов, ни сети — тестируется на байтах.
SrsDump readSrs(Uint8List data) {
  if (data.length < 4 ||
      data[0] != 0x53 ||
      data[1] != 0x52 ||
      data[2] != 0x53) {
    throw const SrsFormatException('bad magic');
  }
  final List<int> body;
  try {
    body = zlib.decode(data.sublist(4));
  } catch (e) {
    throw SrsFormatException('zlib: $e');
  }
  final r = _Reader(Uint8List.fromList(body));
  final out = SrsDump();
  final count = r.uvarint();
  for (var i = 0; i < count; i++) {
    _readRule(r, out, 0);
  }
  return out;
}

const _maxDepth = 100;

void _readRule(_Reader r, SrsDump out, int depth) {
  if (depth > _maxDepth) throw const SrsFormatException('nested too deep');
  final type = r.u8();
  switch (type) {
    case 0:
      _readDefaultRule(r, out);
    case 1:
      r.u8(); // mode: and/or
      final n = r.uvarint();
      for (var i = 0; i < n; i++) {
        _readRule(r, out, depth + 1);
      }
      r.u8(); // invert
    default:
      throw SrsFormatException('rule type $type');
  }
}

void _readDefaultRule(_Reader r, SrsDump out) {
  while (true) {
    final item = r.u8();
    switch (item) {
      case 0: // query_type: []uint16
      case 7: // source_port
      case 9: // port
        r.skip(r.uvarint() * 2);
      case 2: // domain + domain_suffix
        _readDomainMatcher(r, out);
      case 3:
        out.domainKeywords.addAll(r.strings());
      case 4:
        out.domainRegexes.addAll(r.strings());
      case 5: // source_ip_cidr — не наш случай, но разобрать надо
        _readIpSet(r, null);
      case 6:
        _readIpSet(r, out.ipRanges);
      case 1: // network
      case 8: // source_port_range
      case 10: // port_range
      case 11: // process_name
      case 12: // process_path
      case 13: // package_name
      case 14: // wifi_ssid
      case 15: // wifi_bssid
      case 17: // process_path_regex
      case 23: // package_name_regex
        r.strings();
      case 16: // adguard domain — свой trie, в проверке не используется
        _skipAdGuard(r);
      case 18: // network_type: []uint8
        r.skip(r.uvarint());
      case 19: // network_is_expensive
      case 20: // network_is_constrained
        break;
      case 21: // network_interface_address
        final n = r.uvarint();
        for (var i = 0; i < n; i++) {
          r.u8();
          _skipPrefixes(r);
        }
      case 22: // default_interface_address
        _skipPrefixes(r);
      case 0xFF: // final + invert
        r.u8();
        return;
      default:
        throw SrsFormatException('rule item $item');
    }
  }
}

void _skipPrefixes(_Reader r) {
  final n = r.uvarint();
  for (var i = 0; i < n; i++) {
    r.skip(r.uvarint()); // addr
    r.u8(); // bits
  }
}

void _skipAdGuard(_Reader r) {
  r.u8(); // version
  r.skip(r.uvarint() * 8);
  r.skip(r.uvarint() * 8);
  r.skip(r.uvarint());
}

void _readIpSet(_Reader r, List<SrsIpRange>? out) {
  if (r.u8() != 1) throw const SrsFormatException('ip set version');
  final n = r.u64be();
  for (var i = 0; i < n; i++) {
    final from = r.bytes(r.uvarint());
    final to = r.bytes(r.uvarint());
    if (from.length != to.length || (from.length != 4 && from.length != 16)) {
      throw const SrsFormatException('ip set range');
    }
    out?.add(SrsIpRange(from, to));
  }
}

const _prefixLabel = 0x0D; // '\r'
const _rootLabel = 0x0A; // '\n'

void _readDomainMatcher(_Reader r, SrsDump out) {
  r.u8(); // version succinct set
  final leaves = r.u64List();
  final bitmap = r.u64List();
  final labels = r.bytes(r.uvarint());

  bool bit(List<int> bm, int i) {
    final w = i >> 6;
    if (w >= bm.length) return false;
    return (bm[w] >>> (i & 63)) & 1 != 0;
  }

  // LOUDS в BFS-порядке: у узла i — серия нулей (по ребёнку на ноль) и
  // единица-терминатор. Дети нумеруются подряд, метка ребёнка c — labels[c-1].
  final total = labels.length + 1;
  final firstChild = Int32List(total);
  final childCount = Int32List(total);
  var pos = 0;
  var nextChild = 1;
  final nbits = bitmap.length * 64;
  for (var node = 0; node < total && pos < nbits; node++) {
    firstChild[node] = nextChild;
    while (pos < nbits && !bit(bitmap, pos)) {
      nextChild++;
      pos++;
    }
    childCount[node] = nextChild - firstChild[node];
    pos++;
  }
  if (nextChild != total) throw const SrsFormatException('malformed domain set');

  // Обход в глубину без рекурсии: ключ собирается в буфер по пути.
  final keys = <String>[];
  final buf = <int>[];
  final stackNode = <int>[0];
  final stackDepth = <int>[0];
  while (stackNode.isNotEmpty) {
    final node = stackNode.removeLast();
    final depth = stackDepth.removeLast();
    buf.length = depth;
    if (node > 0) buf.add(labels[node - 1]);
    if (bit(leaves, node)) keys.add(_reverse(utf8.decode(buf, allowMalformed: true)));
    for (var c = firstChild[node] + childCount[node] - 1;
        c >= firstChild[node];
        c--) {
      stackNode.add(c);
      stackDepth.add(buf.length);
    }
  }

  // Matcher.Dump(): `\r.x` + `x` → суффикс x; `\r…` → суффикс; `\n…` → суффикс.
  final domainSet = <String>{};
  final prefixSet = <String>{};
  for (final k in keys) {
    if (k.isEmpty) continue;
    final c = k.codeUnitAt(0);
    if (c == _prefixLabel) {
      prefixSet.add(k.substring(1));
    } else if (c == _rootLabel) {
      out.domainSuffixes.add(k.substring(1));
    } else {
      domainSet.add(k);
    }
  }
  for (final p in prefixSet) {
    if (p.startsWith('.') && domainSet.remove(p.substring(1))) {
      out.domainSuffixes.add(p.substring(1));
      continue;
    }
    out.domainSuffixes.add(p);
  }
  out.domains.addAll(domainSet);
}

/// `reverseDomain` ядра — разворот по рунам.
String _reverse(String s) => String.fromCharCodes(s.runes.toList().reversed);

class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  int _p = 0;

  void _need(int n) {
    if (n < 0 || _p + n > _b.length) {
      throw const SrsFormatException('unexpected end of data');
    }
  }

  int u8() {
    _need(1);
    return _b[_p++];
  }

  int uvarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final c = u8();
      result |= (c & 0x7f) << shift;
      if (c < 0x80) return result;
      shift += 7;
      if (shift > 63) throw const SrsFormatException('uvarint overflow');
    }
  }

  int u64be() {
    _need(8);
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | _b[_p++];
    }
    return v;
  }

  List<int> u64List() {
    final n = uvarint();
    _need(n * 8);
    return [for (var i = 0; i < n; i++) u64be()];
  }

  Uint8List bytes(int n) {
    _need(n);
    final out = Uint8List.sublistView(_b, _p, _p + n);
    _p += n;
    return Uint8List.fromList(out);
  }

  void skip(int n) {
    _need(n);
    _p += n;
  }

  List<String> strings() {
    final n = uvarint();
    return [for (var i = 0; i < n; i++) utf8.decode(bytes(uvarint()))];
  }
}
