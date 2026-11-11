# Phase 3: combined trigger conditions

Applied migrations: R070, R071, R072. The existing shared task identity, activity history and default snooze setting remain the foundation.

## Available in the folder editor

- **During a time window**: show only within the chosen hours and weekdays.
- **At a place during a time window**: being there before the window opens is enough.
- **Arrive during a time window**: requires arrival after the window opens and after the task becomes due.
- Existing **At a time** and legacy **When I arrive at a place** continue working.

Due is the earliest eligible date/time. Repeat controls the next occurrence after Done or Skip. Allowed days and hours constrain when an unfinished occurrence may appear; they do not generate duplicate occurrences. A Friday 22:00–02:00 window includes Saturday 01:00. Timezone is saved with the condition.

If a window closes unfinished, the minute sweep logs an automatic snooze using the user's setting (60 minutes if unset). After that snooze, the task still waits for its conditions. Done and Skip keep the existing history and recurrence behavior. Shared status reports `waiting_for_conditions` when a due task cannot currently appear. Conditions follow the stable task ID into subsequent occurrences.

Editing a legacy arrival rule into a window rule uses the existing conversion transaction and preserves task identity/history. Existing rules acquire no new conditions unless edited. Removing conditions via At a time restores normal timed behavior.

## Delivery and location limits

Overlay and phone-push claim use the same server evaluator. The feed includes a validity deadline, so a cached overlay expires even when refresh fails. Push TTL is limited to that deadline; the service worker also rejects expired payloads. Already displayed operating-system notifications cannot be remotely guaranteed to disappear.

Place conditions require the most recent, open matching visit and a heartbeat within five minutes. Unknown, stale, closed or elsewhere observations wait. Presence works with a visit that began before the window; arrival does not. Once an arrival is observed during the window, snoozing within that window does not require leaving and re-entering, but fresh presence remains necessary.

This uses existing app location reporting, not background OS geofencing. If the phone suspends location reporting, Akatsuki cannot confirm presence. The server sweep and time-only windows continue while apps are closed.

## Validation

- Rollback-only database tests cover inside/outside windows, overnight weekdays, default automatic snooze and history, duplicate-sweep prevention, presence versus arrival, stale/departed location, recurrence, retry identity and owner guards.
- DOM tests cover new combined-rule validation/payloads, expiry while offline, and existing create/edit/convert/snooze/skip flows.
- Shared-task client contract tests and JavaScript syntax checks pass.
- Full Chromium/device geolocation validation remains a manual check; DOM tests do not simulate a phone GPS.

Phase 4 remains the broader, easier mobile date/time editor. External app adoption beyond existing shared scripts is separate integration work.
