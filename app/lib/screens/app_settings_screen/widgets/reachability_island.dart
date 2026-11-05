import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/l10n/locale_controller.dart';
import '../../../services/reachability/reachability_logic.dart';
import '../../../services/reachability/reachability_monitor.dart';
import '../../../services/relative_time.dart';
import '../../../widgets/template_var_list.dart';

/// §721 — App Settings → Diagnostics: проверка доступности заблокированных
/// ресурсов через туннель. Самодостаточный: читает и пишет настройки через
/// [ReachabilityMonitor], слушает его статус.
class ReachabilityIsland extends StatefulWidget {
  const ReachabilityIsland({super.key});

  @override
  State<ReachabilityIsland> createState() => _ReachabilityIslandState();
}

class _ReachabilityIslandState extends State<ReachabilityIsland> {
  final _monitor = ReachabilityMonitor.I;

  @override
  void initState() {
    super.initState();
    _monitor.addListener(_onChanged);
  }

  @override
  void dispose() {
    _monitor.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _update(ReachabilitySettings next) =>
      unawaited(_monitor.updateSettings(next));

  String _statusLine() {
    final st = _monitor.status;
    if (_monitor.running) return getLocalText.s("Checking…");
    final skipped = switch (st.skipped) {
      'screen_off' => getLocalText.s("Last tick skipped: the screen was off"),
      'no_candidates' =>
        getLocalText.s("Last tick skipped: the block lists are not downloaded yet"),
      'no_route' =>
        getLocalText.s("Last tick skipped: the route sends everything direct"),
      _ => null,
    };
    final at = st.at;
    final String result;
    if (at == null || st.ok == null) {
      result = getLocalText.s("Not checked yet");
    } else {
      final when = relativeTime(DateTime.now(), at);
      result = st.ok!
          ? getLocalText.s("%1\$s: %2\$d of %3\$d responded", when,
              st.reachable, st.checked)
          : getLocalText.s("%1\$s: none of %2\$d responded", when, st.checked);
    }
    return skipped == null ? result : '$result\n$skipped';
  }

  Future<void> _checkNow() async {
    try {
      await _monitor.runCheck();
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(getLocalText.s("Connect the VPN to run the check"))));
    }
  }

  Widget _dropdown<T>({
    required String title,
    required T value,
    required List<T> values,
    required String Function(T) label,
    required void Function(T) onChanged,
    required bool enabled,
  }) {
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<T>(
        value: value,
        onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
        items: [
          for (final v in values)
            DropdownMenuItem<T>(value: v, child: Text(label(v))),
        ],
      ),
    );
  }

  String _actionLabel(ReachabilityAction a) => switch (a) {
        ReachabilityAction.notify => getLocalText.s("Only notify"),
        ReachabilityAction.resetNetwork => getLocalText.s("Reset network"),
        ReachabilityAction.reconnect => getLocalText.s("Reconnect"),
      };

  @override
  Widget build(BuildContext context) {
    final s = _monitor.settings;
    final on = s.enabled;
    return SettingsIsland(
      title: getLocalText.s("Blocked sites check"),
      description: getLocalText.s(
          "Every few minutes opens a few sites from the Russian block lists through the running tunnel and warns when none of them respond. Off by default: every check is real traffic and some battery."),
      children: [
        SwitchListTile(
          title: Text(getLocalText.s("Check blocked sites")),
          subtitle: Text(_statusLine()),
          value: on,
          onChanged: (v) => _update(s.copyWith(enabled: v)),
        ),
        _dropdown<int>(
          title: getLocalText.s("Interval"),
          value: s.intervalMinutes,
          values: ReachabilitySettings.intervals,
          label: (v) => getLocalText.s("%d min", v),
          onChanged: (v) => _update(s.copyWith(intervalMinutes: v)),
          enabled: on,
        ),
        _dropdown<int>(
          title: getLocalText.s("Sites per check"),
          value: s.sampleSize,
          values: ReachabilitySettings.sampleSizes,
          label: (v) => getLocalText.plural("%d sites", v),
          onChanged: (v) => _update(s.copyWith(sampleSize: v)),
          enabled: on,
        ),
        _dropdown<int>(
          title: getLocalText.s("Timeout per site"),
          value: s.timeoutSeconds,
          values: ReachabilitySettings.timeouts,
          label: (v) => getLocalText.s("%d s", v),
          onChanged: (v) => _update(s.copyWith(timeoutSeconds: v)),
          enabled: on,
        ),
        _dropdown<ReachabilityAction>(
          title: getLocalText.s("On failure"),
          value: s.onFail,
          values: ReachabilityAction.values,
          label: _actionLabel,
          onChanged: (v) => _update(s.copyWith(onFail: v)),
          enabled: on,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Pause while the screen is off")),
          value: s.skipWhenScreenOff,
          onChanged:
              on ? (v) => _update(s.copyWith(skipWhenScreenOff: v)) : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _monitor.running ? null : _checkNow,
              icon: const Icon(Icons.travel_explore, size: 18),
              label: Text(getLocalText.s("Check now")),
            ),
          ),
        ),
      ],
    );
  }
}
