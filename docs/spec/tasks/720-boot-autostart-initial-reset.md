# 720 — Автозапуск после загрузки: начальный resetNetwork, когда сеть появилась после старта ядра

| Field | Value |
|-------|-------|
| Status | Code-complete (ждёт проверки на устройстве) |
| Start date | 2026-11-05 |
| End date | — |
| Commits | ветка `fix/boot-autostart-reset`: `fix(vpn): one-shot resetNetwork when tunnel started before usable network (boot race)` + docs |
| Related specs | [010-VPN_SERVICE → network-changes](../features/010-VPN_SERVICE/FUNCTIONS/network-changes.ru.md), [autostart-and-exit](../features/010-VPN_SERVICE/FUNCTIONS/autostart-and-exit.ru.md), §087, §119, §122, §694, §519/§596 |

## Problem

При включённом «Auto-start on boot» после перезагрузки телефона туннель
формально поднят (Connected), но трафик не идёт, пока пользователь не нажмёт
Reconnect вручную.

## Diagnosis

1. `vpn/BootReceiver.kt` → `onReceive` запускает `BoxVpnService.start()` сразу
   по `BOOT_COMPLETED`. В этот момент физической сети (Wi‑Fi/LTE) обычно ещё нет.
2. Без сети локальный DNS-резолв отвечает ошибкой сразу (§122, Won't-fix):
   резолв адресов серверов и dial аутбаундов на старте ядра падают.
3. `vpn/DefaultNetworkMonitor.kt` → `maybeResetOnSwitch` делает reset только на
   *смену* интерфейса (`prev.isNullOrEmpty() → return`, §087). Появление первой
   сети после загрузки — «первое подключение», reset не происходит, ядро
   остаётся с мёртвыми эндпоинтами и пустым/отравленным DNS-кэшем.

Отвергнутый путь: отложить старт в `BootReceiver` (JobScheduler / ожидание
сети). Сервис — `foregroundServiceType="specialUse"`; исключение на старт FGS
из `BOOT_COMPLETED` действует только во время обработки broadcast'а, отложенный
старт на Android 12+ получает `ForegroundServiceStartNotAllowedException`.

## Solution

Последствия чинятся внутри работающего сервиса, в `DefaultNetworkMonitor`:

- `start()`: если seed-сети нет или у неё нет `NET_CAPABILITY_VALIDATED` —
  взводится одноразовый флаг `awaitingUsableNetwork`, лог
  `[init] no usable network yet — initial reset armed`.
- `notifySync()` (ядро подписалось на монитор): если сеть к этому моменту уже
  VALIDATED — флаг снимается без reset'а (ядро стартует на рабочей сети).
- `checkUpdate()` при взведённом флаге вместо §087 вызывает
  `scheduleInitialReset()`:
  - сеть VALIDATED → reset через обычный debounce 1,5 с;
  - ещё нет → ждать до 10 с (`INITIAL_VALIDATION_WAIT_MS`) и сделать reset в
    любом случае (сети без валидации: заблокирован connectivity-check и т.п.);
  - переход unvalidated → validated перепланирует таймер на короткий;
    churn `onCapabilitiesChanged` с тем же состоянием VALIDATED таймер не
    переносит (`pendingInitialValidated`);
  - потеря сети отменяет запланированный reset, при следующем появлении сети
    он планируется заново.
- По срабатыванию: флаг снимается, лог
  `[boot] first usable network (validated=…) → resetNetwork`, вызывается тот же
  колбэк, что и в §087 (`commandServer.resetNetwork()` в `BoxService`).
- Учтён `isMetered()` из §694 (аргумент `updateDefaultInterface` не менялся).
- Дополнительно `pendingInitialValidated` помечен `@Volatile`: пишется из
  IO-корутины reset'а, читается из потока колбэков сети (как и соседние поля).

Ветка §087 не тронута: после первого reset'а (или снятия флага в `notifySync`)
все последующие события идут по старому пути.

## Risks and edge cases

- **Таймаут connecting-фазы — отдельный путь, патч его не трогает.** Если ядро
  без сети не дошло до `Started` за порог Dart-стороны
  (`home_controller.dart`: база 15 с, +10 с на каждый WG/AWG-endpoint §519,
  +0,1 с на узел свыше 150 §596, потолок 4 мин), safety-таймер переводит туннель
  в ошибку/останов — это не «Connected без трафика», и начальный reset его не
  спасает. Граница зафиксирована здесь; если на устройстве встретится —
  отдельная задача.
- Сеть, которая так и не получает VALIDATED (connectivity-check заблокирован),
  при **ручном** старте даёт один лишний reset через 10 с после появления
  интерфейса. Цена — один `CloseAll` в первые секунды сессии; критерий «нет
  лишнего reset'а при ручном старте» сформулирован для валидной сети.
- `ProbeSession` (§237-fix) тоже поднимает `DefaultNetworkMonitor` с пустым
  колбэком: при старте пробы без валидной сети в логе может появиться
  `[boot] … → resetNetwork`, но колбэк ничего не делает. При живом VPN проба
  идёт через live-ядро и монитор не запускает.
- Гонка «таймер reset'а сработал одновременно с потерей сети»: reset уйдёт на
  пустой интерфейс — безвреден, следующий switch пойдёт по §087.

## Verification

- Сборка: `./gradlew :app:compileDebugKotlin` (см. отчёт в коммите/PR).
- Unit-тест не добавлен: решение завязано на `ConnectivityManager` и корутины
  объекта-синглтона; в `src/test` нет Robolectric/моков Android, а вынесение
  логики в чистый класс — переписывание проверенного патча. Проверка — на
  устройстве.
- Ручная проверка (на устройстве, оператор):
  - [ ] Автозапуск вкл, перезагрузка → туннель рабочий без ручных действий:
    только Wi‑Fi; только LTE; авиарежим → потом сеть.
  - [ ] `adb logcat -s LxBoxNet` — ровно один `[boot] … → resetNetwork` за загрузку.
  - [ ] Смена Wi‑Fi↔LTE на живом туннеле — один reset, как раньше (§087,
    регрессия класса sing-box #3400).
  - [ ] Ручной старт при валидной сети — ни одной строки `[boot]`.

## Unresolved / follow-up

- Путь «ядро не уложилось в connecting-таймаут при загрузке без сети» — см.
  Risks; заводится отдельной задачей по факту воспроизведения.
