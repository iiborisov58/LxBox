# 722 — Русификация: аудит остатков

| Field | Value |
|-------|-------|
| Status | Code-complete (скриншоты на эмуляторе не сняты — см. Verification) |
| Start date | 2026-11-05 |
| End date | — |
| Commits | ветка `l10n/ru-audit`: `fix(l10n): аудит русских остатков (722)` |
| Related specs | [029-LOCALIZATION](../features/029-LOCALIZATION/FEATURE.ru.md), [`docs/l10n.md`](../../l10n.md), §279, §285, `62a2c04e` |

## Problem

Русский интерфейс есть и закрыт CI (`ru/ui.json` — 2156 ключей, пустых нет;
`hardcoded_baseline.json` пуст). Остались: ключи, у которых перевод совпадает с
английским (38), 150 мест `// l10n-exempt`, тексты в обход `getLocalText`.
Нужно разобрать их по одному: перевести / оставить / сменить причину.

Принцип 029: логи, Debug API, события автоматизации, значения конфига и
wire-значения остаются английскими; названия протоколов, брендов и вендоров не
переводятся.

## Diagnosis

### 1. 38 ключей, совпадающих с английским

| Ключ | Где | Решение | Обоснование |
|------|-----|---------|-------------|
| `Start` | кнопка главного экрана | **оставить** | решение владельца `62a2c04e`: русское слово выталкивало кнопку перезагрузки за край |
| `Stop` | главный экран; диалог «остановить VPN»; кнопки уведомления в настройках; Run/Stop в URL-check | **перевести** «Остановить», для главной — форма `special["1"]` = `Stop` | на главной ограничение `62a2c04e` сохраняется; в остальных местах английское «Stop» было побочным эффектом общего ключа (подпись кнопки уведомления расходилась с самим уведомлением — там `notification_action_stop` = «Остановить») |
| `up` / `down` / `sleep` / `off` | подпись состояния WG/AWG-endpoint'а в строке узла и экране outbound | **перевести** «на связи» / «нет связи» / «сон» / «выкл.» | обычный текст интерфейса, не wire: значение ядра маппится в подпись (`node_row.dart`), сама строка ядра показывается отдельно на экране outbound |
| `START` / `STOP` | кнопка записи Live events | **перевести** «СТАРТ» / «СТОП» (+ подсказка «Нажмите СТАРТ…») | кнопка, не идентификатор; соседние заголовки капсом переведены («ПАРАМЕТРЫ», «СЕТЬ И ПРОТОКОЛ»); в zh подсказка ссылалась на `START`, а кнопка — `启动`: выровнено |
| `INBOUND` | заголовок секции редактора правила | **перевести** «ВХОДЯЩИЙ ИНТЕРФЕЙС» (zh `入站`) | соседние секции переведены; описание уже по-русски («Через какой интерфейс пришёл пакет») |
| `Start timed out after %1$d s (post-start did not finish, %2$d endpoints)` | причина остановки (`StopStartTimeout.messageWith`) — баннер на главной | **перевести** | пользовательская ошибка; машинный дубль идёт через `renderEn()` и остаётся английским |
| `Auto · %s` | регион в настройках | **оставить** | согласовано с `Auto · страна не определена`: «Auto» в этой плитке везде латиницей |
| `Detour` | заголовок настроек узла/подписки | **оставить** | термин sing-box и имя фичи (006-DETOUR_AND_BALANCE), в ru-текстах «detour-сервер» |
| `detour → %s` | подпись цикла detour | **оставить** | то же |
| `Endpoint IP` | мастер WARP | **оставить** | имя поля WireGuard (`Endpoint`) |
| `Hostcheck` | форма openconnect | **оставить** | имя функции шлюза Fortinet (вендор) |
| `Exit node` / `exit node` | Tailscale | **оставить** | термин продукта Tailscale |
| `Authority` | URL-check, секция DNS-ответа | **оставить** | имя секции DNS-сообщения (как в `dig`) |
| `Hosts` | тип DNS-сервера | **оставить** | тип сервера sing-box `hosts` |
| `final` / `srs` / `SRS: %s` / `SRS: %s (+%d)` | фильтр профайлера, вид DNS-правила, подпись правила | **оставить** | wire-значения sing-box |
| `OOM` | вкладка Debug | **оставить** | аббревиатура |
| `DNS`, `TLS`, `IP`, `JSON`, `HTTP`, `HTTP %d`, `SOCKS5`, `SSID`, `URL`, `JSON outbound` | разное | **оставить** | термины/аббревиатуры |
| `192.168.1.1 / dns.example.com`, `… / https://… URL`, `1–200` | подсказки полей | **оставить** | примеры значений, слов нет |

### 2. 150 `l10n-exempt`

Распределение причин: protocol name 27, technology name 8, vendor name 6,
sing-box wire value 4, duration literal 4, endonym 3, broadcast event names 3,
brand name 3, acronym 3, далее по 1–2. Проверены все причины класса
«technical term / unit / duration / … as is».

| Место | Было | Решение |
|-------|------|---------|
| `screens/diagnostics/url_check_tab.dart` `_ageText` | `'$sec s'` / `'… min'` / `'… h'`, причина «units» — показывалось внутри переведённой фразы («Из кэша, возраст 5 min») | **перевести**: `%d s` / `%d min` / `%d h` |
| `screens/speed_test_screen.dart` `_routeForHistory` | `'Direct'`, причина «outbound tag-like label» — это подпись в истории прогонов, а не тег | **перевести**: `Direct` → «Напрямую» (как соседнее `Direct (no VPN)`) |
| `screens/outbound_view_screen.dart` `_endpointStateValue` | `'$st · idle for $idle s'` — наша английская фраза, не текст ядра, без исключения и в обход `getLocalText` (чекер её не ловит: возврат из функции, не display-позиция) | **перевести**: `%1$s · idle for %2$d s`; `$st` (строка ядра) остаётся как есть |
| `url_check_tab.dart` `'${s.durationMs} ms'`, `pool_view_dialog`, `probe_badge`, `speed_test` `…ms` | «unit» / «latency value + unit» | **оставить**: `ms` латиницей во всех локалях — решение спеки §5 (так же помечено в другом месте «'ms' — латинская единица в обеих локалях») |
| `direction_edit_screen`, `source_replace_screen`, `dns_server_edit` (`15m`, `30m`, `2m`, `5m`) | «duration literal/example» | **оставить**: подсказка формата, который пользователь вводит (длительность sing-box) |
| `openconnect_form` `SNI`, `MTU` | «technical term» | **оставить** (аббревиатуры) |
| `openconnect_auth_ui` (текст и ошибка шлюза, ссылка входа) | «gateway text as is» | **оставить**: текст присылает шлюз VPN, перевести нечем |
| `node_row` / `tailscale_network_tab` (состояние/ошибка ядра) | «core state/error text as is» | **оставить** — см. п. 3 |
| `mixin_edit_screen` `op.name` | «verb name as stored» | **оставить**: имя операции миксина = wire |
| `speed_test_screen` `'—'`, `'↑—'`, `chain_positions_block` `'1.'`, `tailscale` `' · '` | маркеры/числа | **оставить** |

Остальные причины (protocol/technology/vendor/brand name, endonym, wire,
broadcast event names, примеры значений) корректны.

### 3. Тексты в обход `getLocalText`

- `renderEn()` вне `lib/models/*`: все вызовы — в AppLog, Debug API,
  automation-броадкастах и `emitWarnings` (которые уходят только в AppLog,
  `subscription_controller.dart` → `AppLog.I.warning`). `lastStartError` —
  только Debug API. Пользовательских строк среди них нет.
- Ошибки ядра у пинга/URLTest/диагностики (`formatUserError` → `RawMsg`)
  показываются как есть (`context deadline exceeded`, `connection refused`).
  Обещание 009 «не заставлять расшифровывать английские ошибки ядра» покрыто
  вердиктами core-reject (с дословной причиной ядра — по спеке) и
  `TimeoutError`, но не частыми сетевыми ошибками пинга. Это не остаток
  перевода, а отдельная фича (словарь вердиктов) — follow-up.
- Уведомления и плитка: нативные строки — `values-ru/strings.xml` +
  `L10n.kt`, `kotlin_check --strict` чист.

### 4. Термины

Механическая сверка словаря: «node» ↔ «узел», «server» ↔ «сервер»,
«Direction» ↔ «Направление», «tunnel» ↔ «туннель» — расхождений нет (одно
`node`→«detour-серверы» — по смыслу верно). Найдены две ссылки на экраны,
оставленные по-английски внутри русского текста:
- «…добавьте узел на экране Servers» → «на экране «Серверы»» (заголовок экрана
  `Servers` = «Серверы»);
- «Правила маршрутизации и Tunnel apps действуют…» → «…и «Приложения туннеля»…»
  (заголовок `Tunnel apps` = «Приложения туннеля»).

### 5. Пользовательская документация

Не проводилась (необязательный пункт); после этой правки в `USER_GUIDE.ru.md`
стоит сверить упоминания кнопки «Stop» вне главного экрана и состояния
endpoint'ов («up/sleep/down»).

## Solution

- `ru/ui.json`, `zh/ui.json`: переводы по таблицам выше; новые ключи `Direct`,
  `%d s`, `%d min`, `%d h`, `%1$s · idle for %2$d s`; у `Stop` — форма
  `special["1"]` (ru — `Stop`, zh — `停止`).
- `home_controls.dart` — `getLocalText.s(1, "Stop")`.
- `url_check_tab.dart`, `speed_test_screen.dart`, `outbound_view_screen.dart` —
  через `getLocalText`, исключения сняты.
- Machine-поверхности (Debug API, события, логи) не менялись: правки только в
  виджетах и словарях.

## Risks and edge cases

- `нет связи` / `на связи` длиннее `up`/`down`: подпись 10 pt, одна строка с
  ellipsis — обрежется, но не переполнит строку.
- Ключи `%d s` / `%d min` добавлены и в ветке задачи 721
  (`feat/blocked-reachability`) с теми же переводами: при слиянии обеих веток
  в `ui.json` будет текстовый конфликт, разрешается оставлением одной копии.

## Verification

- `flutter analyze` — чисто; `tool/l10n/*` ×4 `--strict` — 0 находок (ru/zh:
  2161 ключ, missing/orphan 0); связанные тесты (stop_reason, ui_msg,
  node_row endpoint, outbound view, speed test, test/tool, l10n) — 147 passed.
- Скриншоты до/после на эмуляторе **не сняты**: на машине нет эмулятора и
  system image, а сборка APK требует `scripts/fetch-libbox.sh` (запуск
  заблокирован в этой сессии). Нужен прогон оператором: главная (Start/Stop),
  строка WG-узла, Live events, редактор правила (секция INBOUND), URL-check.

## Unresolved / follow-up

- Словарь вердиктов для частых сетевых ошибок ядра в пинге/диагностике (п. 3).
- Сверка `USER_GUIDE.ru.md` (п. 5).
