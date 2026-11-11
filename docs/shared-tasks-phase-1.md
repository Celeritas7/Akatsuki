# Shared tasks — Phase 1

`akatsuki_tasks.id` is the stable task identity. Broadcast IDs identify individual occurrences; arrival rule IDs identify rules. Both now carry `task_id`. A recurring series and an arrival rule converted to a timed reminder keep the task identity.

Existing broadcasts and rules are backfilled without changing their due times, states, or history. Legacy source_app uses created_by where available, otherwise akatsuki. This preserves provenance labels, including arrival labels, rather than guessing the original app. Legacy task_type is other; source_url is unset until the origin app supplies it.

Apps register using their authenticated Supabase client and `js/akatsuki-tasks.js`. Reusing `(user_id, source_app, source_task_id)` returns the same task. `source_task_id` must be a durable local identifier, never a title. Supply `taskId` when attaching origin metadata to an existing Akatsuki task; its ID and reminders are retained. Conflicting identities fail rather than merge silently. Only the signed-in owner's records are readable or editable. App names are provenance labels, not separate authorization boundaries.

```js
const tasks = AkatsukiTasks(supabase, 'chatak');
const taskId = await tasks.register({
  sourceTaskId: 'shopping-item-123', title: 'Buy detergent', type: 'buy',
  url: 'https://example.com/items/123'
});
const sharedStatus = await tasks.get('shopping-item-123');
```

Registration alone does not schedule a notification. Integrating source apps and their trigger registration is a later phase. Phase 1 introduces no polling service, new trigger logic, auto-snooze, action-event history, or automatic connection to every app.

## Read contract

`akatsuki_task_status` is an owner-filtered security-invoker view. It returns identity and origin metadata, display_title, status, occurrence_id, next_show_at, last_result, last_completed_at and status_updated_at. Status is derived from live reminder records rather than a second writable copy.

Statuses: registered, waiting_for_arrival, scheduled, pending, snoozed, paused, done, skipped, cancelled, triggered. Pending means the existing timed due threshold is reached; it does not prove a notification was delivered. Triggered means a one-shot arrival rule fired. Actual notification delivery and user-action event history belong to later phases.

A recurring task may be scheduled for its next occurrence while last_result is done or skipped for the previous occurrence. An active arrival rule can be waiting_for_arrival after a previous message was completed. next_show_at is meaningful only with a scheduled/pending/snoozed occurrence; it is not an estimated arrival time.

The original app reads this view when it reconnects. Done, Skip, Pause, Snooze and Resume through existing RPCs are reflected immediately. No change to another app's own task table is implied.

## Review checkpoint

Confirm stable identity across repeat completion and arrival-to-time conversion; duplicate registration returns one ID; source metadata can be attached without replacing reminders; status follows existing actions; another account cannot read or alter the task. Existing reminder UI remains unchanged.
