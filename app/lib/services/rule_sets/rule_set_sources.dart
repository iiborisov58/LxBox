import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// §723 — вид каталога источника: фильтр поиска, а не семантика ядра.
enum RuleSetKind {
  geosite,
  geoip,
  mixed;

  static RuleSetKind? parse(Object? v) {
    for (final k in values) {
      if (k.name == v) return k;
    }
    return null;
  }
}

/// Каталог внутри ветки источника. `path` пустой — корень ветки.
class RuleSetSourceDir {
  const RuleSetSourceDir(this.path, this.kind);

  final String path;
  final RuleSetKind kind;
}

/// §723 — источник `.srs` из реестра контракта (`rule_set_sources.json`).
/// Пока лаунчер его не принял, файл живёт черновиком в
/// `assets/contract_draft/` — см. [RuleSetSources.load].
class RuleSetSource {
  const RuleSetSource({
    required this.id,
    required this.title,
    required this.repo,
    required this.ref,
    required this.dirs,
    this.jsdelivrList = false,
    this.note = '',
  });

  final String id;
  final String title;

  /// `owner/name` на GitHub.
  final String repo;

  /// Ветка с бинарниками (`release`, `rule-set`, `sing`…).
  final String ref;
  final List<RuleSetSourceDir> dirs;

  /// Можно ли брать список у jsDelivr, когда GitHub API не ответил. Для
  /// репозиториев больше 50 МБ jsDelivr листинг не отдаёт (403) — там false.
  final bool jsdelivrList;
  final String note;

  String get homepage => 'https://github.com/$repo/tree/$ref';
}

/// Разобранный реестр источников.
class RuleSetSources {
  const RuleSetSources(this.sources, this.listTtl);

  final List<RuleSetSource> sources;

  /// Сколько живёт кеш списка файлов.
  final Duration listTtl;

  static const registryPath =
      'assets/contract/registry/rule_set_sources.json';
  static const draftPath = 'assets/contract_draft/rule_set_sources.json';

  /// Реестр, если файл приехал контрактом, иначе черновик — тот же порядок,
  /// что у секций-мапперов (§480): зеркало реестра лаунчер пересобирает
  /// бампом, и править его здесь нельзя (`check_contract_lock`).
  static Future<RuleSetSources> load() async {
    String text;
    try {
      text = await rootBundle.loadString(registryPath);
    } catch (_) {
      text = await rootBundle.loadString(draftPath);
    }
    return parse(text);
  }

  /// Строгий разбор: битый реестр — ошибка сразу, а не пустой список, в
  /// котором «ничего не нашлось».
  static RuleSetSources parse(String text) {
    final root = jsonDecode(text);
    if (root is! Map || root['v'] != 1) {
      throw const FormatException('rule_set_sources: v != 1');
    }
    final body = root['rule_set_sources'];
    if (body is! Map) throw const FormatException('rule_set_sources: no body');
    final ttl = (body['list_ttl_hours'] as Map?)?['value'];
    if (ttl is! int || ttl <= 0) {
      throw const FormatException('rule_set_sources: list_ttl_hours');
    }
    final list = body['sources'];
    if (list is! List || list.isEmpty) {
      throw const FormatException('rule_set_sources: sources');
    }
    final ids = <String>{};
    final out = <RuleSetSource>[];
    for (final s in list) {
      if (s is! Map) throw const FormatException('rule_set_sources: entry');
      final id = s['id'], title = s['title'], repo = s['repo'], ref = s['ref'];
      if (id is! String || id.isEmpty || !ids.add(id)) {
        throw FormatException('rule_set_sources: id "$id"');
      }
      if (title is! String || title.isEmpty) {
        throw FormatException('rule_set_sources: $id title');
      }
      if (repo is! String || !_repoForm.hasMatch(repo)) {
        throw FormatException('rule_set_sources: $id repo "$repo"');
      }
      if (ref is! String || ref.isEmpty) {
        throw FormatException('rule_set_sources: $id ref');
      }
      final dirsRaw = s['dirs'];
      if (dirsRaw is! List || dirsRaw.isEmpty) {
        throw FormatException('rule_set_sources: $id dirs');
      }
      final dirs = <RuleSetSourceDir>[];
      for (final d in dirsRaw) {
        final path = d is Map ? d['path'] : null;
        final kind = d is Map ? RuleSetKind.parse(d['kind']) : null;
        if (path is! String ||
            path.startsWith('/') ||
            path.endsWith('/') ||
            kind == null) {
          throw FormatException('rule_set_sources: $id dir $d');
        }
        dirs.add(RuleSetSourceDir(path, kind));
      }
      out.add(
        RuleSetSource(
          id: id,
          title: title,
          repo: repo,
          ref: ref,
          dirs: dirs,
          jsdelivrList: s['jsdelivr_list'] == true,
          note: s['note'] is String ? s['note'] as String : '',
        ),
      );
    }
    return RuleSetSources(out, Duration(hours: ttl));
  }

  static final _repoForm = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
}
