import 'dart:async';

import 'package:flutter/material.dart';

import '../models/custom_rule.dart';
import '../services/domain_helper/domain_candidates.dart';
import '../services/domain_helper/exit_probe.dart';
import '../services/domain_helper/public_suffix.dart';
import '../services/domain_helper/rule_coverage.dart';
import '../services/l10n/locale_controller.dart';
import '../services/reachability/reachability_monitor.dart';
import '../services/rule_sets/rule_set_catalog.dart';
import '../services/settings_storage.dart';
import '../services/traffic_profiler.dart';
import '../widgets/safe_bottom.dart';
import 'app_picker_screen.dart';
import 'rule_set_finder_screen.dart';

/// §724 — что помощник вернул в редактор Inline-правила.
class DomainHelperResult {
  const DomainHelperResult(this.domains, this.suffixes);

  final List<String> domains;
  final List<String> suffixes;
}

/// Тестовые шовы помощника: всё, что ходит в платформу, ядро или диск.
class DomainHelperDeps {
  const DomainHelperDeps({
    this.loadPsl,
    this.loadRules,
    this.pickApps,
    this.tunnelConnected,
    this.proxyTag,
    this.probe,
    this.catalog,
  });

  final Future<PublicSuffixList> Function()? loadPsl;
  final Future<List<CustomRule>> Function()? loadRules;
  final Future<List<String>?> Function(BuildContext)? pickApps;
  final bool Function()? tunnelConnected;
  final String? Function()? proxyTag;
  final ExitProbeFn? probe;
  final RuleSetCatalog? catalog;
}

/// §724 — помощник подбора доменов (spec 724): кандидаты из записи
/// приложения, текста или набора правил → свёртка по PSL → покрытие своими
/// правилами → проверка выхода → выбранное возвращается в поля правила.
///
/// Сеть — только по кнопкам: проверка выхода и загрузка набора правил.
class DomainHelperScreen extends StatefulWidget {
  const DomainHelperScreen({
    super.key,
    this.excludeRuleId,
    this.deps = const DomainHelperDeps(),
  });

  /// Редактируемое правило — в покрытии не участвует.
  final String? excludeRuleId;
  final DomainHelperDeps deps;

  @override
  State<DomainHelperScreen> createState() => _DomainHelperScreenState();
}

class _DomainHelperScreenState extends State<DomainHelperScreen> {
  PublicSuffixList? _psl;
  RuleCoverage _coverage = RuleCoverage.empty;
  final Map<String, DomainCandidate> _candidates = {};
  List<CandidateGroup> _groups = const [];
  final Map<String, bool> _selected = {};
  final Map<String, bool> _asSuffix = {};
  final Map<String, ExitCheck> _exits = {};
  int _ipOnly = 0;
  bool _checking = false;
  bool _loadingSet = false;
  String? _error;

  // Запись приложения.
  Set<String>? _recordPackages;
  bool _weStartedRecording = false;
  Timer? _tick;

  /// Сколько групп проверять за раз: каждая — до двух запросов через ядро.
  static const _maxExitChecks = 30;

  DomainHelperDeps get _d => widget.deps;
  TrafficProfiler get _profiler => TrafficProfiler.I;

  bool get _tunnelUp =>
      (_d.tunnelConnected ?? ReachabilityMonitor.I.host?.tunnelConnected)
          ?.call() ??
      false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final psl = await (_d.loadPsl ?? PublicSuffixList.load)();
      final rules = await (_d.loadRules ?? SettingsStorage.getCustomRules)();
      final cov = await RuleCoverage.build(
        rules,
        excludeId: widget.excludeRuleId,
      );
      if (!mounted) return;
      setState(() {
        _psl = psl;
        _coverage = cov;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_weStartedRecording) _profiler.stopGlobalRecording();
    super.dispose();
  }

  void _addCandidates(Iterable<DomainCandidate> list) {
    final psl = _psl;
    if (psl == null) return;
    for (final c in list) {
      final have = _candidates[c.host];
      if (have == null) {
        _candidates[c.host] = c;
      } else {
        have.sources.addAll(c.sources);
        have.connections += c.connections;
        have.outbounds.addAll(c.outbounds);
        have.fromSuffix |= c.fromSuffix;
      }
    }
    // Группы пересобираются с нуля: хост мог перейти в уже известную группу.
    _groups = groupCandidates(
      _candidates.values.map(
        (c) => DomainCandidate(c.host)
          ..sources.addAll(c.sources)
          ..connections = c.connections
          ..outbounds.addAll(c.outbounds)
          ..fromSuffix = c.fromSuffix,
      ),
      psl,
    );
    for (final g in _groups) {
      _selected.putIfAbsent(g.key, () => true);
      _asSuffix.putIfAbsent(
        g.key,
        () =>
            g.suffixAllowed &&
            (g.hosts.length > 1 || g.hosts.any((h) => h.fromSuffix)),
      );
    }
  }

  // ─── Источники ──────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final picked = await (_d.pickApps ?? _pickAppsDefault)(context);
    if (picked == null || picked.isEmpty || !mounted) return;
    if (_profiler.isGlobalRecording) {
      final restart = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(getLocalText.s("Profiler is already recording")),
          content: Text(
            getLocalText.s(
              "Use the events of the current recording, or start a new one? A new recording clears the profiler log.",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel")),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(getLocalText.s("Start over")),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Use current")),
            ),
          ],
        ),
      );
      if (restart == null || !mounted) return;
      if (restart) {
        _profiler.stopGlobalRecording();
        _profiler.startGlobalRecording();
        _weStartedRecording = true;
      }
    } else {
      _profiler.startGlobalRecording();
      _weStartedRecording = true;
    }
    setState(() => _recordPackages = picked.toSet());
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  static Future<List<String>?> _pickAppsDefault(BuildContext context) async {
    final r = await Navigator.push<AppPickerResult>(
      context,
      MaterialPageRoute(builder: (_) => const AppPickerScreen(selected: {})),
    );
    return r?.packages;
  }

  RecordedHosts _recorded() =>
      hostsFromEvents(_profiler.globalRollingBuffer, _recordPackages ?? {});

  void _finishRecording({bool keep = true}) {
    final r = _recorded();
    _tick?.cancel();
    if (_weStartedRecording) _profiler.stopGlobalRecording();
    _weStartedRecording = false;
    setState(() {
      if (keep) {
        _addCandidates(r.candidates);
        _ipOnly += r.ipOnlyConnections;
      }
      _recordPackages = null;
    });
  }

  Future<void> _pasteText() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _PasteDialog(),
    );
    final psl = _psl;
    if (text == null || psl == null || !mounted) return;
    final hosts = extractHosts(text, psl);
    setState(
      () => _addCandidates([
        for (final h in hosts)
          DomainCandidate(h)..sources.add(CandidateSource.text),
      ]),
    );
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("No domains found in the text"))),
      );
    }
  }

  Future<void> _fromRuleSet() async {
    final url = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => RuleSetFinderScreen(catalog: _d.catalog),
      ),
    );
    if (url == null || !mounted) return;
    setState(() {
      _loadingSet = true;
      _error = null;
    });
    try {
      final dump = await (_d.catalog ?? RuleSetCatalog()).fetchAndRead(url);
      if (!mounted) return;
      setState(
        () => _addCandidates([
          for (final d in dump.domains)
            if (normalizeHost(d) case final h?)
              DomainCandidate(h)..sources.add(CandidateSource.ruleSet),
          for (final s in dump.domainSuffixes)
            if (normalizeHost(s) case final h?)
              DomainCandidate(h)
                ..sources.add(CandidateSource.ruleSet)
                ..fromSuffix = true,
        ]),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = getLocalText.s("Download failed: %s", e));
      }
    } finally {
      if (mounted) setState(() => _loadingSet = false);
    }
  }

  // ─── Проверка выхода ────────────────────────────────────────────────────

  Future<void> _checkExits() async {
    final targets = [
      for (final g in _groups)
        if (_selected[g.key] == true) g,
    ].take(_maxExitChecks).toList();
    if (targets.isEmpty) return;
    final proxy = (_d.proxyTag ?? ReachabilityMonitor.I.host?.routeFinalTag)
        ?.call();
    setState(() => _checking = true);
    try {
      // По четыре группы параллельно: ядро не заваливаем, но и не ждём
      // 30 × 5 с подряд.
      for (var i = 0; i < targets.length; i += 4) {
        await Future.wait([
          for (final g in targets.skip(i).take(4))
            () async {
              final host = _probeHost(g);
              final r = await checkExits(
                host,
                proxyTag: proxy,
                probe: _d.probe,
              );
              if (mounted) setState(() => _exits[g.key] = r);
            }(),
        ]);
        if (!mounted) return;
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Хост для пробы: самый «живой» из записи, иначе точный домен группы.
  /// Суффикс из набора правил может не резолвиться сам — но другого адреса у
  /// такой группы нет.
  static String _probeHost(CandidateGroup g) {
    final hosts = [...g.hosts]
      ..sort((a, b) => b.connections.compareTo(a.connections));
    return hosts.first.host;
  }

  void _apply() {
    final domains = <String>[], suffixes = <String>[];
    for (final g in _groups) {
      if (_selected[g.key] != true) continue;
      if (g.suffixAllowed && _asSuffix[g.key] == true) {
        suffixes.add(g.key);
      } else {
        domains.addAll(g.hosts.map((h) => h.host));
      }
    }
    Navigator.pop(context, DomainHelperResult(domains, suffixes));
  }

  // ─── UI ─────────────────────────────────────────────────────────────────

  String _sourceLabel(CandidateSource s) => switch (s) {
    CandidateSource.recorded => getLocalText.s("recorded"),
    CandidateSource.text => getLocalText.s("from text"),
    CandidateSource.ruleSet => getLocalText.s("from rule set"),
  };

  String _verdict(ExitCheck c) => switch (c.verdict) {
    ExitVerdict.direct => getLocalText.s("Works direct"),
    ExitVerdict.proxyOnly => getLocalText.s("Only via proxy"),
    ExitVerdict.none => getLocalText.s("No response"),
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = TextStyle(
      fontSize: 12,
      color: t.colorScheme.onSurfaceVariant,
    );
    final selectedCount = _selected.values.where((v) => v).length;
    final ready = _psl != null;
    final recording = _recordPackages != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Pick domains")),
        actions: [
          TextButton(
            onPressed: selectedCount == 0 || recording ? null : _apply,
            child: Text(getLocalText.s("Add (%d)", selectedCount)),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.fiber_manual_record, size: 16),
                  label: Text(getLocalText.s("Record app")),
                  onPressed: ready && !recording ? _startRecording : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: Text(getLocalText.s("Paste text")),
                  onPressed: ready && !recording ? _pasteText : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.travel_explore, size: 16),
                  label: Text(getLocalText.s("From rule set")),
                  onPressed: ready && !recording && !_loadingSet
                      ? _fromRuleSet
                      : null,
                ),
              ],
            ),
          ),
          if (recording) _recordingCard(t, muted),
          if (_loadingSet) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: t.colorScheme.error),
              ),
            ),
          if (_ipOnly > 0 || _coverage.missingSrsRules.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                [
                  if (_ipOnly > 0)
                    getLocalText.s(
                      "Connections without a domain (IP only): %d — a domain rule will not catch them",
                      _ipOnly,
                    ),
                  if (_coverage.missingSrsRules.isNotEmpty)
                    getLocalText.s(
                      "Not downloaded, not checked: %s",
                      _coverage.missingSrsRules.join(', '),
                    ),
                ].join('\n'),
                style: muted,
              ),
            ),
          if (_groups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      getLocalText.s("Groups: %d", _groups.length),
                      style: muted,
                    ),
                  ),
                  TextButton.icon(
                    icon: _checking
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : const Icon(Icons.network_check, size: 16),
                    label: Text(getLocalText.s("Check exits")),
                    onPressed: _checking || recording || !_tunnelUp
                        ? null
                        : _checkExits,
                  ),
                ],
              ),
            ),
          if (_groups.isNotEmpty && !_tunnelUp)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                getLocalText.s("Exit check needs the VPN to be connected"),
                style: muted,
              ),
            ),
          Expanded(
            child: !ready && _error == null
                ? const Center(child: CircularProgressIndicator())
                : _groups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        getLocalText.s(
                          "Record an app, paste a list or take a rule set — the helper will fold the domains into rule entries and show which of your rules already match them.",
                        ),
                        textAlign: TextAlign.center,
                        style: muted,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero.withSafeBottom(context),
                    itemCount: _groups.length,
                    itemBuilder: (_, i) => _groupTile(_groups[i], t, muted),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _recordingCard(ThemeData t, TextStyle muted) {
    final r = _recorded();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              getLocalText.s("Recording: %s", _recordPackages!.join(', ')),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              getLocalText.s(
                "Switch to the app, do what should work (update, download, sign in), then come back and tap Done.",
              ),
              style: muted,
            ),
            if (!_tunnelUp)
              Text(
                getLocalText.s(
                  "VPN is not connected — nothing will be recorded.",
                ),
                style: TextStyle(fontSize: 12, color: t.colorScheme.error),
              ),
            const SizedBox(height: 4),
            Text(
              getLocalText.s(
                "Domains so far: %1\$d · IP only: %2\$d",
                r.candidates.length,
                r.ipOnlyConnections,
              ),
              style: const TextStyle(fontSize: 12),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _finishRecording(keep: false),
                  child: Text(getLocalText.s("Cancel")),
                ),
                FilledButton(
                  onPressed: _finishRecording,
                  child: Text(getLocalText.s("Done")),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTile(CandidateGroup g, ThemeData t, TextStyle muted) {
    final asSuffix = g.suffixAllowed && _asSuffix[g.key] == true;
    final cover = _coverage.coverOf(g.hosts.first.host);
    final exit = _exits[g.key];
    final lines = <String>[
      if (!asSuffix || g.hosts.length > 1 || g.hosts.first.host != g.key)
        g.hosts.map((h) => h.host).take(5).join(', ') +
            (g.hosts.length > 5 ? ' (+${g.hosts.length - 5})' : ''),
      g.sources.map(_sourceLabel).join(' · ') +
          (g.connections > 0
              ? ' · ${getLocalText.s("connections: %d", g.connections)}'
              : ''),
    ];
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: _selected[g.key] ?? false,
      onChanged: (v) => setState(() => _selected[g.key] = v ?? false),
      title: Text(
        asSuffix ? getLocalText.s("suffix %s", g.key) : g.key,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines) Text(l, style: muted),
          if (cover != null)
            Text(
              getLocalText.s(
                "Already matched by rule «%1\$s» → %2\$s",
                cover.ruleName,
                cover.outbound.isEmpty ? '—' : cover.outbound,
              ),
              style: TextStyle(fontSize: 12, color: t.colorScheme.tertiary),
            ),
          if (exit != null)
            Text(
              _verdict(exit),
              style: TextStyle(
                fontSize: 12,
                color: switch (exit.verdict) {
                  ExitVerdict.direct => Colors.green,
                  ExitVerdict.proxyOnly => t.colorScheme.primary,
                  ExitVerdict.none => t.colorScheme.error,
                },
              ),
            ),
        ],
      ),
      secondary: g.suffixAllowed
          ? TextButton(
              onPressed: () => setState(() => _asSuffix[g.key] = !asSuffix),
              child: Text(
                asSuffix ? getLocalText.s("Suffix") : getLocalText.s("Exact"),
              ),
            )
          : null,
    );
  }
}

/// Диалог вставки текста: свой State держит контроллер, чтобы тот жил, пока
/// диалог доигрывает анимацию закрытия.
class _PasteDialog extends StatefulWidget {
  const _PasteDialog();

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(getLocalText.s("Paste text with domains")),
    content: TextField(
      controller: _ctrl,
      autofocus: true,
      maxLines: 10,
      minLines: 4,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        hintText: getLocalText.s(
          "A list, links or any text: domains are picked out of it",
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(getLocalText.s("Cancel")),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _ctrl.text),
        child: Text(getLocalText.s("Extract")),
      ),
    ],
  );
}
