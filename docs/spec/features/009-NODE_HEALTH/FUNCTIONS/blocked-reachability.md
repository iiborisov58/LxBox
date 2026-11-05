[English](blocked-reachability.md) · [Русский](blocked-reachability.ru.md)

# Blocked-sites check — periodic proof that blocked resources open through the tunnel

An opt-in timer that, while the tunnel is connected, opens a few sites from
the Russian block lists through the running core and warns when none of them
respond: it catches "the tunnel is Connected, but blocked sites do not open"
(for example DPI cutting the flow).

| Field | Value |
|------|----------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P18 |
| State | ✅ implemented, 2026-11-05 ([721](../../../tasks/721-blocked-reachability-check.md)) |

## What it does

Every interval it picks a few hosts from the block lists, sends one HTTPS
request to each through the running core (the node is addressed by the tag of
`route.final`, the same mechanism as node diagnostics P13) and records the
result: success if **at least one** answered. On failure it reacts as the
user chose: a notification (default), a core network reset, or a reconnect.

## Parameters

App Settings → Diagnostics → "Blocked sites check".

| Setting | Values | Default |
|---------|--------|---------|
| Check blocked sites | on / off | **off** |
| Interval | 5 / 15 / 30 / 60 min | 15 min |
| Sites per check | 3 / 4 / 5 | 3 |
| Timeout per site | 3 / 5 / 10 s | 5 s |
| On failure | Only notify / Reset network / Reconnect | Only notify |
| Pause while the screen is off | on / off | on |

Fixed values: the first check — 60 s after Connected; the lists are refreshed
with a conditional GET once every 168 h (as the template's runetfreedom
presets).

Sources (runetfreedom, sing-box binary rule-sets):
`geosite-ru-blocked.srs` (domains) and `geoip-ru-blocked-community.srs`
(IP ranges). They are **not** added to routing presets: the check uses them on
its own, in the same `rule_sets/` cache under the `reachability__` id prefix
(not pruned as orphans).

## Inputs / Outputs

**Inputs:** tunnel state; the running config's `route.final`; the screen state;
the two rule-sets; the core's `getURLViaOutbound` reply.

**Outputs:** the status line in the settings ("<when>: N of M responded" /
"none of M responded" / why the last tick was skipped); a `[reachability]`
line in the app log ([013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md));
automation events `REACHABILITY_FAILED` / `REACHABILITY_RESTORED` (Health,
[014-AUTOMATION](../../014-AUTOMATION/FUNCTIONS/outbound-events.md)); Debug API
`GET|PUT /settings/reachability`, `POST /action/reachability-check`; on
failure — a notification, `resetNetwork` or a reconnect.

## Rules and invariants

- **Off by default.** It runs only while the tunnel is Connected; any
  transition to down (an explicit Stop, an error, a revoke, the heartbeat
  verdict) cancels the timer and any pending reaction.
- **Through the core, not through the app process.** The request goes to the
  live core by the `route.final` tag; the active selector is not switched, the
  app opens no sockets. `route.final = direct-out` — the tick is skipped
  (`no_route`): checking a direct route proves nothing.
- **Candidates.** From geosite only `domain` and `domain_suffix` (a suffix is
  checked as a host); `domain_keyword` and `domain_regex` are dropped, as are
  names without a dot, with a mask or non-ASCII. geoip is secondary: only IPv4
  ranges of ≤ 4 addresses; an address enters the sample only if a check on it
  already succeeded, or if there are fewer hosts than the sample size. The
  parsed candidate list is cached on disk and re-parsed only when a rule-set
  file changes.
- **Sample.** N random targets per check; the previous check's targets are
  not repeated in the next one while there are enough candidates.
- **Verdict.** A target is reachable on any HTTP status (as P13) or on a
  certificate error (the TLS handshake took place — the server answered); a
  timeout, reset or EOF is unreachable. The check fails only if **none** of
  the N answered.
- **Reaction.** `resetNetwork` / reconnect — at most once per interval and
  only if the tunnel is still Connected and was not stopped while the check
  ran (P12 of 010: an explicit Stop is not resurrected). The notification —
  once per failure streak; the first success after a failure removes it and
  emits `REACHABILITY_RESTORED`.
- **Screen off.** With the option on (default) a tick with the screen off is
  skipped (`screen_off`) and the next one is planned as usual.
- **No server addresses** in events, logs and notifications (P14 of 014):
  events carry only counts and the reaction name; core error texts in the log
  pass through address masking.

## Boundaries

- Runs in the app's Flutter engine: if the process is killed while the tunnel
  lives on in the service, checks stop until the app is opened again.
- It does not check the live route with rules and sniffing — only the
  `route.final` outbound (the boundary of core SPEC 058 §5, as P13).
- An IP target is checked with HTTPS to the address; a server that drops
  connections without SNI counts as unreachable — that is why IPs are only a
  secondary source.
- The lists are external (runetfreedom); their content and availability are
  not ours. Without both lists the tick is skipped (`no_candidates`).

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [721](../../../tasks/721-blocked-reachability-check.md) | Implemented | Opt-in blocked-sites check through the live core; reactions; Health events |
