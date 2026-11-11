# Phase 2 — action history and default snooze

Broadcasts home now has Reminder settings → Default snooze (minutes), 1–10080 minutes. Until saved, the default is 60 minutes. This setting belongs to the signed-in account and is shared across devices/apps using the updated broadcaster.

The due-task overlay adds Snooze (saved duration). Existing 10 minute / 1 hour / 3 hour choices and explicit rescheduling remain. Skip… opens Do later (default snooze), Skip this occurrence, and Back. Skipping never cancels the recurring series; existing recurrence behaviour is preserved.

Activity history is available on Broadcasts home and in each folder. It displays up to the latest 100 global events, filtered by folder when applicable. Older complete history remains in the database and can be queried by task. Archive retains existing completed/closed occurrences. Historical events before installation are not fabricated.

## Shared contract

- `akatsuki_task_events`: owner-readable, client writes forbidden. Includes stable task ID, occurrence ID, event type, timestamp, app when known, and a title/category snapshot.
- Server triggers record scheduled, snoozed, rescheduled, done, skipped, cancelled, paused, resumed, edited and arrival-rule creation/edit/cancel/firing. Explicit rescheduling through the existing snoozed_until API is recorded as snoozed with its next show time.
- `akatsuki_broadcast_shown`: records a client display receipt only for a due, scheduled occurrence. Deduplicated by owner, occurrence, show time and app. It does not prove push delivery or that the user read the message.
- `akatsuki_broadcast_snooze_default`: uses the saved default and expected show time. Repeated/stale requests are no-ops; completion on another device cannot be undone.
- `akatsuki_reminder_settings_set`: owner-checked and validated save.
- `AkatsukiTasks(client, app).history(taskId, limit)` reads newest events first. Ownership is enforced by RLS; app labels are provenance, not authorization boundaries.

Default snooze changes no task identity and creates no extra occurrence. Done/Skip retry protection and recurrence remain in the original RPCs. Conversion from arrival to timed moves the provisional creation log to the stable task identity before cleanup.

## Next phase boundary

Automatic snooze at a time-window boundary requires Phase 3's combined trigger/window evaluator. Phase 2 installs the saved default and action history it will use; it does not invent a timeout for existing reminders or change their trigger conditions. Background notification delivery and app-specific integration remain separate work.

## Validation

Run `tests/task-history.sql` after R069; it rolls back test settings and rows. It checks shown-receipt deduplication, saved default, stale snooze retries, action history, recurring identity, arrival conversion with event references, and owner isolation. Existing DOM tests include the default Snooze, Skip choices and settings save. Browser runtime validation is separate from DOM tests.
