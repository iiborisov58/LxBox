import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../reachability/srs_reader.dart';
import '../subscription/user_agent.dart';
import 'rule_set_sources.dart';

/// §723 — файл `.srs` в каталоге источника.
class RuleSetEntry {
  const RuleSetEntry({
    required this.sourceId,
    required this.dir,
    required this.name,
    required this.kind,
    this.size,
  });

  final String sourceId;
  final String dir;
  final String name;
  final RuleSetKind kind;
  final int? size;

  String get path => dir.isEmpty ? name : '$dir/$name';

  /// Имя без `.srs` и без префикса `geosite-`/`geoip-`: по нему ранжируется
  /// поиск, чтобы «youtube» находил `geosite-youtube.srs` первым.
  String get stem {
    var s = name.toLowerCase();
    if (s.endsWith('.srs')) s = s.substring(0, s.length - 4);
    for (final p in const ['geosite-', 'geoip-']) {
      if (s.startsWith(p)) return s.substring(p.length);
    }
    return s;
  }

  Map<String, Object?> toJson() => {
    'dir': dir,
    'name': name,
    'kind': kind.name,
    'size': size,
  };

  static RuleSetEntry? fromJson(String sourceId, Object? j) {
    if (j is! Map) return null;
    final name = j['name'], dir = j['dir'];
    final kind = RuleSetKind.parse(j['kind']);
    if (name is! String || dir is! String || kind == null) return null;
    final size = j['size'];
    return RuleSetEntry(
      sourceId: sourceId,
      dir: dir,
      name: name,
      kind: kind,
      size: size is int ? size : null,
    );
  }
}

/// Откуда качать файл. В правило пишется URL выбранного зеркала.
enum RuleSetMirror { github, jsdelivr }

String _encodePath(String path) => Uri(path: path).path;

String ruleSetUrl(
  RuleSetSource s,
  RuleSetEntry e,
  RuleSetMirror m,
) => switch (m) {
  RuleSetMirror.github =>
    'https://raw.githubusercontent.com/${s.repo}/${s.ref}/${_encodePath(e.path)}',
  RuleSetMirror.jsdelivr =>
    'https://cdn.jsdelivr.net/gh/${s.repo}@${s.ref}/${_encodePath(e.path)}',
};

/// GitHub API: содержимое одного каталога ветки, без рекурсии. Рекурсивное
/// дерево у больших репозиториев усекается (MetaCubeX — 27 МБ, truncated).
Uri gitTreeUri(RuleSetSource s, RuleSetSourceDir d) => Uri.parse(
  'https://api.github.com/repos/${s.repo}/git/trees/'
  '${s.ref}${d.path.isEmpty ? '' : ':${_encodePath(d.path)}'}',
);

Uri jsdelivrListUri(RuleSetSource s) => Uri.parse(
  'https://data.jsdelivr.com/v1/packages/gh/${s.repo}@${s.ref}?structure=flat',
);

/// Разбор ответа `git/trees/<ref>:<dir>`: файлы `.srs` каталога.
List<RuleSetEntry> parseGitTree(
  String body,
  RuleSetSource s,
  RuleSetSourceDir d,
) {
  final j = jsonDecode(body);
  final tree = j is Map ? j['tree'] : null;
  if (tree is! List) throw const FormatException('no tree');
  return [
    for (final t in tree)
      if (t is Map &&
          t['type'] == 'blob' &&
          t['path'] is String &&
          (t['path'] as String).endsWith('.srs'))
        RuleSetEntry(
          sourceId: s.id,
          dir: d.path,
          name: t['path'] as String,
          kind: d.kind,
          size: t['size'] is int ? t['size'] as int : null,
        ),
  ];
}

/// Разбор flat-листинга jsDelivr: файлы `.srs` прямо в каталоге [d], без
/// вложенных — как у GitHub-пути.
List<RuleSetEntry> parseJsdelivrFlat(
  String body,
  RuleSetSource s,
  RuleSetSourceDir d,
) {
  final j = jsonDecode(body);
  final files = j is Map ? j['files'] : null;
  if (files is! List) throw const FormatException('no files');
  final prefix = d.path.isEmpty ? '/' : '/${d.path}/';
  final out = <RuleSetEntry>[];
  for (final f in files) {
    if (f is! Map) continue;
    final n = f['name'];
    if (n is! String || !n.startsWith(prefix) || !n.endsWith('.srs')) continue;
    final rest = n.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) continue;
    out.add(
      RuleSetEntry(
        sourceId: s.id,
        dir: d.path,
        name: rest,
        kind: d.kind,
        size: f['size'] is int ? f['size'] as int : null,
      ),
    );
  }
  return out;
}

/// Список одного источника: файлы, когда снят, и ошибка последней попытки.
/// Ошибка при непустом списке — показываем старый список с пометкой.
class SourceListing {
  const SourceListing(this.entries, this.fetchedAt, [this.error]);

  final List<RuleSetEntry> entries;
  final DateTime? fetchedAt;
  final String? error;
}

/// §723 — поиск по [entries]: подстрока имени без регистра. Порядок — точное
/// имя (без `.srs`/префикса вида), начало, вхождение; внутри — короче выше,
/// затем по алфавиту. Фильтр вида пропускает `mixed` в обе стороны: в таком
/// каталоге лежат и домены, и IP.
List<RuleSetEntry> searchRuleSets(
  Iterable<RuleSetEntry> entries,
  String query, {
  Set<String>? sources,
  RuleSetKind? kind,
}) {
  final q = query.trim().toLowerCase();
  final hits = <(int, RuleSetEntry)>[];
  for (final e in entries) {
    if (sources != null && !sources.contains(e.sourceId)) continue;
    if (kind != null && e.kind != kind && e.kind != RuleSetKind.mixed) {
      continue;
    }
    if (q.isEmpty) {
      hits.add((2, e));
      continue;
    }
    final stem = e.stem;
    final int rank;
    if (stem == q || e.name.toLowerCase() == q) {
      rank = 0;
    } else if (stem.startsWith(q)) {
      rank = 1;
    } else if (e.name.toLowerCase().contains(q)) {
      rank = 2;
    } else {
      continue;
    }
    hits.add((rank, e));
  }
  hits.sort((a, b) {
    final r = a.$1.compareTo(b.$1);
    if (r != 0) return r;
    final l = a.$2.stem.length.compareTo(b.$2.stem.length);
    if (l != 0) return l;
    return a.$2.name.compareTo(b.$2.name);
  });
  return [for (final h in hits) h.$2];
}

/// §723 — списки файлов источников с кешем на диске.
///
/// Сеть — только из [load], а его зовёт экран поиска, открытый пользователем
/// (§395). Источники опрашиваются параллельно; сбой одного не мешает другим.
class RuleSetCatalog {
  RuleSetCatalog({
    http.Client? client,
    Future<File> Function()? cacheFile,
    DateTime Function()? now,
  }) : _client = client,
       _cacheFile = cacheFile ?? _defaultCacheFile,
       _now = now ?? DateTime.now;

  final http.Client? _client;
  final Future<File> Function() _cacheFile;
  final DateTime Function() _now;

  static const _timeout = Duration(seconds: 20);

  static Future<File> _defaultCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/rule_set_catalog.json');
  }

  Future<http.Response> _get(Uri uri) {
    final headers = {'User-Agent': resolveAppUserAgent()};
    final c = _client;
    return (c != null
            ? c.get(uri, headers: headers)
            : http.get(uri, headers: headers))
        .timeout(_timeout);
  }

  /// Списки всех источников. Свежий кеш (моложе `listTtl`) — без сети;
  /// [force] — перезапросить все.
  Future<Map<String, SourceListing>> load(
    RuleSetSources reg, {
    bool force = false,
  }) async {
    final cached = await _readCache(reg);
    final now = _now();
    final out = <String, SourceListing>{};
    await Future.wait([
      for (final s in reg.sources)
        () async {
          final c = cached[s.id];
          final fresh =
              c?.fetchedAt != null &&
              now.difference(c!.fetchedAt!) < reg.listTtl &&
              !now.isBefore(c.fetchedAt!);
          if (!force && fresh) {
            out[s.id] = c;
            return;
          }
          try {
            out[s.id] = SourceListing(await _fetchSource(s), now);
          } catch (e) {
            out[s.id] = SourceListing(
              c?.entries ?? const [],
              c?.fetchedAt,
              _short(e),
            );
          }
        }(),
    ]);
    await _writeCache(out);
    return out;
  }

  Future<List<RuleSetEntry>> _fetchSource(RuleSetSource s) async {
    Object githubError;
    try {
      final parts = await Future.wait([
        for (final d in s.dirs)
          _get(gitTreeUri(s, d)).then((r) {
            if (r.statusCode != 200) {
              throw HttpException('GitHub HTTP ${r.statusCode}');
            }
            return parseGitTree(r.body, s, d);
          }),
      ]);
      return [for (final p in parts) ...p];
    } catch (e) {
      githubError = e;
    }
    if (!s.jsdelivrList) throw githubError;
    final r = await _get(jsdelivrListUri(s));
    if (r.statusCode != 200) {
      throw HttpException(
        '${_short(githubError)}; jsDelivr HTTP ${r.statusCode}',
      );
    }
    return [for (final d in s.dirs) ...parseJsdelivrFlat(r.body, s, d)];
  }

  static String _short(Object e) => switch (e) {
    HttpException(:final message) => message,
    FormatException(:final message) => message,
    _ => e.toString(),
  };

  Future<Map<String, SourceListing>> _readCache(RuleSetSources reg) async {
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return {};
      final out = <String, SourceListing>{};
      for (final s in reg.sources) {
        final e = j[s.id];
        if (e is! Map) continue;
        final at = DateTime.tryParse('${e['fetched_at']}');
        final list = e['entries'];
        if (list is! List) continue;
        out[s.id] = SourceListing([
          for (final x in list) ?RuleSetEntry.fromJson(s.id, x),
        ], at);
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeCache(Map<String, SourceListing> data) async {
    try {
      final f = await _cacheFile();
      await f.writeAsString(
        jsonEncode({
          for (final MapEntry(:key, :value) in data.entries)
            if (value.fetchedAt != null)
              key: {
                'fetched_at': value.fetchedAt!.toIso8601String(),
                'entries': [for (final e in value.entries) e.toJson()],
              },
        }),
      );
    } catch (_) {
      // Кеш — удобство: не записался, значит в следующий раз спросим сеть.
    }
  }

  /// Предел скачивания для проверки: крупнейшие файлы источников — единицы МБ.
  static const maxFileBytes = 32 * 1024 * 1024;

  /// Скачать файл и разобрать в изоляте. Ошибка сети, размера или формата —
  /// исключение с коротким текстом для экрана.
  Future<SrsDump> fetchAndRead(String url) async {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = resolveAppUserAgent();
    final c = _client ?? http.Client();
    try {
      final resp = await c.send(req).timeout(_timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final buf = BytesBuilder(copy: false);
      await for (final chunk in resp.stream.timeout(_timeout)) {
        buf.add(chunk);
        if (buf.length > maxFileBytes) {
          throw const HttpException('file is larger than 32 MB');
        }
      }
      final bytes = buf.takeBytes();
      return await Isolate.run(() => readSrs(bytes));
    } finally {
      if (_client == null) c.close();
    }
  }
}
