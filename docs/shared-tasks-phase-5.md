# Phase 5: source-app integration — first rollout

Prepared changes (not deployed):
- Owner-guarded atomic `akatsuki_app_task_save` registers the stable origin identity and saves a reminder with the Phase 3 conditions in one transaction. A per-task row lock and expected occurrence ID prevent two devices creating duplicate active occurrences. Retry keys remain tied to their original task. History and recurring occurrences retain the origin identity.
- `AkatsukiTasks.schedule()` exposes this contract to other apps.
- `AkatsukiBroadcastPanel.openTask(seed)` reads fresh shared status before opening the Phase 4 editor. Existing snoozed/paused/conditioned tasks edit the current occurrence; the dialog displays last result as well as current status. Read failures do not offer an unsafe new-task form. Source dialogs cannot navigate into another task under the original identity.
- Chatak product detail gains a schedule/status button keyed by product ID. Demo products cannot create tasks.
- Cost recurring-template rows gain a schedule/status button keyed by template ID. This is an explicit separate reminder schedule; monthly expense templates are not silently converted to fixed-day repeats.

This rollout does not migrate all existing app reminders or Albert reminders. Existing native price alerts and Cost's recurring expense prompts stay intact. Completing a reminder does not record a purchase/expense. Source app data remain authoritative; Akatsuki's shared status is read back when the dialog opens. More adapters and legacy reminder migration remain before Phase 5 is complete.

## Release order and current blocker

The Supabase migration confirmation expired twice; R074 has NOT been applied. Database rollback tests are prepared but cannot pass until the function exists. Do not merge/deploy dependent app controls yet.

1. Apply `sql/akatsuki_app_tasks_R074.sql` to the existing General_apps project.
2. Run `tests/app-tasks.sql` (BEGIN/ROLLBACK), preceding phase regression SQL tests and database advisors. Verify owner isolation and concurrent-save behavior.
3. Merge/publish Akatsuki, then Chatak and Cost draft changes.
4. Verify a source task can be scheduled, snoozed in a second app, reopened with that status, and completed without duplicate occurrences or native expense writes.

DOM tests pass for new source scheduling, existing-state readback, expected occurrence ID, failure handling, and prior editor flows. Full phone/browser and live database validation remain pending.
