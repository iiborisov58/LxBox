import 'package:flutter/material.dart';

import '../services/format_utils.dart' show formatBytes;
import '../services/l10n/locale_controller.dart';
import '../services/relative_time.dart';
import '../services/reachability/srs_reader.dart' show SrsFormatException;
import '../services/rule_sets/rule_set_catalog.dart';
import '../services/rule_sets/rule_set_sources.dart';
import '../services/rule_sets/srs_match.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/safe_bottom.dart';

/// §723 — поиск готового `.srs` по источникам из реестра контракта
/// (`registry/rule_set_sources.json`). Возвращает выбранный URL.
///
/// Сеть — только по действию пользователя (§395): список — при открытии
/// экрана (из кеша, если свежий) и по «Обновить», файл — по «Проверить».
class RuleSetFinderScreen extends StatefulWidget {
  const RuleSetFinderScreen({super.key, this.catalog, this.sources});

  /// Тестовые шовы: подставной каталог и реестр.
  final RuleSetCatalog? catalog;
  final RuleSetSources? sources;

  @override
  State<RuleSetFinderScreen> createState() => _RuleSetFinderScreenState();
}

class _RuleSetFinderScreenState extends State<RuleSetFinderScreen> {
  late final RuleSetCatalog _catalog = widget.catalog ?? RuleSetCatalog();
  final _query = TextEditingController();

  RuleSetSources? _reg;
  Map<String, SourceListing> _lists = const {};
  bool _loading = true;
  String? _fatal;

  /// Выбранные источники; пусто — все.
  final Set<String> _sources = {};
  RuleSetKind? _kind;

  static const _maxShown = 200;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _loading = true);
    try {
      final reg = _reg ?? widget.sources ?? await RuleSetSources.load();
      final lists = await _catalog.load(reg, force: force);
      if (!mounted) return;
      setState(() {
        _reg = reg;
        _lists = lists;
        _fatal = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fatal = e.toString();
        _loading = false;
      });
    }
  }

  RuleSetSource? _source(String id) {
    for (final s in _reg?.sources ?? const <RuleSetSource>[]) {
      if (s.id == id) return s;
    }
    return null;
  }

  String _kindLabel(RuleSetKind k) => switch (k) {
    // l10n-exempt: имена видов rule-set'ов sing-box, не переводятся
    RuleSetKind.geosite => 'geosite',
    // l10n-exempt: имена видов rule-set'ов sing-box, не переводятся
    RuleSetKind.geoip => 'geoip',
    RuleSetKind.mixed => getLocalText.s("Mixed"),
  };

  Future<void> _openEntry(RuleSetEntry e) async {
    final s = _source(e.sourceId);
    if (s == null) return;
    final url = await showAppBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EntrySheet(source: s, entry: e, catalog: _catalog),
    );
    if (url != null && mounted) Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final reg = _reg;
    final all = [
      for (final s in reg?.sources ?? const <RuleSetSource>[])
        ...?_lists[s.id]?.entries,
    ];
    final hits = searchRuleSets(
      all,
      _query.text,
      sources: _sources.isEmpty ? null : _sources,
      kind: _kind,
    );
    final errors = [
      for (final s in reg?.sources ?? const <RuleSetSource>[])
        if (_lists[s.id]?.error case final err?) (s, err),
    ];
    DateTime? oldest;
    for (final l in _lists.values) {
      final at = l.fetchedAt;
      if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Find rule set")),
        actions: [
          IconButton(
            tooltip: getLocalText.s("Refresh list"),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(force: true),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: getLocalText.s("Name, e.g. youtube or ru-blocked"),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(_query.clear),
                      ),
              ),
            ),
          ),
          if (reg != null)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final k in [
                    null,
                    RuleSetKind.geosite,
                    RuleSetKind.geoip,
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: ChoiceChip(
                        label: Text(
                          k == null ? getLocalText.s("All") : _kindLabel(k),
                        ),
                        selected: _kind == k,
                        onSelected: (_) => setState(() => _kind = k),
                      ),
                    ),
                  const VerticalDivider(width: 12),
                  for (final s in reg.sources)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: FilterChip(
                        label: Text(s.title),
                        selected: _sources.contains(s.id),
                        onSelected: (on) => setState(
                          () => on ? _sources.add(s.id) : _sources.remove(s.id),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          for (final (s, err) in errors)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
              child: Text(
                getLocalText.s("%1\$s: list unavailable (%2\$s)", s.title, err),
                style: TextStyle(fontSize: 11, color: t.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              [
                if (!_loading && _fatal == null)
                  hits.length > _maxShown
                      ? getLocalText.s(
                          "Shown %1\$d of %2\$d",
                          _maxShown,
                          hits.length,
                        )
                      : getLocalText.s("Found: %d", hits.length),
                if (oldest != null)
                  getLocalText.s(
                    "list from %s",
                    relativeTime(DateTime.now(), oldest),
                  ),
              ].join(' · '),
              style: TextStyle(
                fontSize: 11,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _fatal != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_fatal!, textAlign: TextAlign.center),
                    ),
                  )
                : !_loading && hits.isEmpty
                ? Center(child: Text(getLocalText.s("Nothing found")))
                : ListView.builder(
                    padding: EdgeInsets.zero.withSafeBottom(context),
                    itemCount: hits.length.clamp(0, _maxShown),
                    itemBuilder: (_, i) {
                      final e = hits[i];
                      final s = _source(e.sourceId);
                      return ListTile(
                        dense: true,
                        title: Text(
                          e.name,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          [
                            s?.title ?? e.sourceId,
                            _kindLabel(e.kind),
                            if (e.size case final size?)
                              formatBytes(size, spaced: true),
                          ].join(' · '),
                        ),
                        onTap: () => _openEntry(e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Карточка файла: зеркало, проверка содержимого, «Использовать».
class _EntrySheet extends StatefulWidget {
  const _EntrySheet({
    required this.source,
    required this.entry,
    required this.catalog,
  });

  final RuleSetSource source;
  final RuleSetEntry entry;
  final RuleSetCatalog catalog;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  RuleSetMirror _mirror = RuleSetMirror.github;
  bool _checking = false;
  String? _checkError;
  SrsIndex? _index;
  final _probe = TextEditingController();
  String? _probeResult;
  bool _probeHit = false;

  String get _url => ruleSetUrl(widget.source, widget.entry, _mirror);

  @override
  void dispose() {
    _probe.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checkError = null;
      _index = null;
      _probeResult = null;
    });
    try {
      final dump = await widget.catalog.fetchAndRead(_url);
      if (!mounted) return;
      setState(() => _index = SrsIndex(dump));
    } on SrsFormatException catch (e) {
      if (mounted) {
        setState(
          () => _checkError = getLocalText.s(
            "Not a valid rule set: %s",
            e.message,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkError = getLocalText.s("Download failed: %s", e));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _runProbe() {
    final idx = _index;
    if (idx == null || SrsIndex.normalizeQuery(_probe.text) == null) return;
    final hit = idx.match(_probe.text);
    setState(() {
      _probeHit = hit != null;
      _probeResult = switch (hit?.kind) {
        null => getLocalText.s("Not found in this file"),
        SrsHitKind.domain => getLocalText.s("Found: domain %s", hit!.value),
        SrsHitKind.suffix => getLocalText.s(
          "Found: domain suffix %s",
          hit!.value,
        ),
        SrsHitKind.keyword => getLocalText.s("Found: keyword %s", hit!.value),
        SrsHitKind.regex => getLocalText.s("Found: regex %s", hit!.value),
        SrsHitKind.ip => getLocalText.s("Found: IP range %s", hit!.value),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = TextStyle(
      fontSize: 12,
      color: t.colorScheme.onSurfaceVariant,
    );
    final idx = _index;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.entry.name,
            style: t.textTheme.titleMedium?.copyWith(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 2),
          Text('${widget.source.repo} @ ${widget.source.ref}', style: muted),
          if (widget.source.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(widget.source.note, style: muted),
          ],
          const SizedBox(height: 12),
          SegmentedButton<RuleSetMirror>(
            segments: const [
              ButtonSegment(
                value: RuleSetMirror.github,
                label: Text('GitHub raw'), // l10n-exempt: имя сервиса
              ),
              ButtonSegment(
                value: RuleSetMirror.jsdelivr,
                label: Text('jsDelivr'), // l10n-exempt: имя сервиса
              ),
            ],
            selected: {_mirror},
            onSelectionChanged: (v) => setState(() {
              _mirror = v.first;
              _index = null;
              _checkError = null;
              _probeResult = null;
            }),
          ),
          const SizedBox(height: 6),
          SelectableText(
            _url,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: _checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      : const Icon(Icons.fact_check_outlined, size: 18),
                  label: Text(getLocalText.s("Check file")),
                  onPressed: _checking ? null : _check,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.add_link, size: 18),
                  label: Text(getLocalText.s("Use")),
                  onPressed: () => Navigator.pop(context, _url),
                ),
              ),
            ],
          ),
          if (_checkError != null) ...[
            const SizedBox(height: 8),
            Text(
              _checkError!,
              style: TextStyle(fontSize: 12, color: t.colorScheme.error),
            ),
          ],
          if (idx != null) ...[
            const SizedBox(height: 12),
            Text(
              [
                getLocalText.s("Domains: %d", idx.dump.domains.length),
                getLocalText.s(
                  "Domain suffixes: %d",
                  idx.dump.domainSuffixes.length,
                ),
                getLocalText.s("Keywords: %d", idx.dump.domainKeywords.length),
                getLocalText.s("Regex: %d", idx.dump.domainRegexes.length),
                getLocalText.s("IPv4 ranges: %d", idx.ipv4Ranges),
                getLocalText.s("IPv6 ranges: %d", idx.ipv6Ranges),
              ].join('\n'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _probe,
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _runProbe(),
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                labelText: getLocalText.s("Domain or IP"),
                suffixIcon: IconButton(
                  tooltip: getLocalText.s("Check"),
                  icon: const Icon(Icons.search, size: 20),
                  onPressed: _runProbe,
                ),
              ),
            ),
            if (_probeResult != null) ...[
              const SizedBox(height: 6),
              Text(
                _probeResult!,
                style: TextStyle(
                  fontSize: 13,
                  color: _probeHit
                      ? Colors.green
                      : t.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
