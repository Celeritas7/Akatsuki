# Phase 4: mobile rule editor

The editor now has separate native Date and Time fields, shortcuts for Today, Tomorrow, In 7 days and In 1 hour, and explicit device-timezone guidance. Calendar-day shortcuts preserve the chosen time; In 1 hour sets both fields. Existing timestamps are preserved if unchanged.

Window rules call the earliest date/time “Start checking from”, with Every day, Weekdays and Weekends presets. Individual weekdays remain editable. The place selection sits beside the trigger choice. Legacy arrival frequency is labeled separately from recurrence.

A live plain-language summary describes the date, window, weekdays, place requirement, overnight ending, recurrence and automatic snooze. The save button remains reachable in a sticky footer. Recurrence choices are Once only, Every day, Every week and Every N days. No database migration or change to trigger evaluation is required. Build R073 refreshes the cached shell.

Validation: DOM tests cover date/time shortcuts, missing-date rejection, weekday presets, overnight summaries and existing rule create/edit/convert/save-failure paths. Shared-task contract and JS syntax checks pass. Chromium was attempted but its process singleton socket is denied by this execution environment; visual/device validation remains unverified.
