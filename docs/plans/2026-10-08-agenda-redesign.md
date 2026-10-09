# Agenda Redesign: Shared Model

The Mac (`Sources/Orgstar/AgendaView.swift`) and iOS (`Sources/OrgstarMobile/AgendaScreen.swift`) agendas are rebuilt on one platform-neutral row model. Item selection stays `Agenda.list`, oracle-tested against Emacs; only the settings below change which items appear.

## Row anatomy

`AgendaRow` (`Sources/OrgPresentation/AgendaRows.swift`):

| Part | Field |
| --- | --- |
| Gutter: time or short status | `gutter`, `status`, `icon` |
| Category line above the title | `category` (entry category, or the event's calendar title) |
| Title without keyword, `[#A]`, statistics cookies, timestamps, tags; links as descriptions | `title` |
| Tags | `tags` (inherited first) |
| TODO keyword | `todo`, `isDone` |
| Priority letter | `priority` |
| Statistics cookie | `progress` (`1/3`, `50%`) |
| Times, `HHMM` | `start`, `end` |
| Deadline / scheduled day | `planningDay` (`Days` numbering) |
| Source | `item: AgendaItem?` (for the existing actions), `event: AgendaEvent?`, `isEvent`, `color` (calendar color) |

`AgendaRow.init?(item:day:today:)` returns nil for time-grid and current-time items.

## Gutter rules

Timed rows show `08:00` or `13:50–14:30` (zero-padded, en dash; past midnight wraps). Untimed rows:

| Kind | Gutter | Status |
| --- | --- | --- |
| Deadline, on today | `Due today` | due-soon |
| Deadline, on today, past | `3d late` | overdue |
| Deadline, on today, upcoming | `Due in 2d` | due-soon |
| Deadline, on another day | `Due` | overdue if before today, else normal |
| Scheduled | `Scheduled` | overdue if before today, else normal |
| Scheduled, carried to today | `Sched. 4d ago` | overdue |
| Habit | `Habit` | overdue if scheduled before today |
| Timestamp, diary sexp | `All day` | normal |
| Range, middle days | `Day 2/5` | normal |
| Log mode | `Closed`, `Clocked`, `State` (when untimed) | normal |
| TODO / match list | empty, no icon | normal |
| Calendar event | `All day`, times, `22:00` on the start day of a multi-day event, `Until 02:00` on its last day | normal |

A done keyword makes the status `done`. Icons: `scheduled`, `deadline`, `habit`, `event`, `timestamp`.

## Ages

`AgendaAge.compact(days)` (`Sources/OrgCore/Agenda/AgendaItemText.swift`): under 14 days `3d`; under 60 whole weeks `2w`; under 365 30-day months `4mo` (at most 11); then 365-day years with remaining months, `1y`, `1y 4mo`. Rounds down; sign ignored.

## Grouping

`AgendaRows.groups(days, events:, today:, showAllDates:, calendar:, keep:) -> [AgendaDayGroup]`, or `AgendaModel.groups(showAllDates:keep:)`.

- Days with no rows are dropped unless `org-agenda-show-all-dates`. Today always stays (`isEmpty` true for the empty state).
- On today, past-scheduled entries and past deadlines (not habits) go in `overdue`, oldest `planningDay` first, Org's order for ties. Oldest first was chosen over Org's urgency order so the list reads as a backlog.
- `rows` keep Org's order (`habit-down time-up urgency-down`). All-day events go first, as calendars show them; timed events go among timed entries by start, after entries at the same time and before untimed entries and habits.
- `keep` is the `AgendaFilter`; events are never filtered.
- Row ids are unique within a group.

## Now marker

`AgendaDayGroup.nowIndex(now: HHMM) -> Int?`: draw the line before `rows[index]`. It goes before the first timed row starting after now, or after the last timed row when all have started. Nil on other days and when no row is timed (Org adds the line only with timed entries). Rows starting exactly at now count as started.

## Settings (config.toml)

| Key | Default | Read with |
| --- | --- | --- |
| `org-agenda-show-all-dates` | `false` (Org's default is `t`) | `OrgPreferences.agendaShowAllDates()` |
| `org-agenda-skip-scheduled-if-done` | `false` (Org's) | `OrgPreferences.agendaOptions(_:)` |
| `org-agenda-skip-deadline-if-done` | `false` (Org's) | `OrgPreferences.agendaOptions(_:)` |
| `[orgstar] calendar-events` | `false` | `OrgPreferences.calendarEvents()` |
| `[orgstar] calendar-event-calendars` | `""` (all), comma-separated titles or identifiers | `OrgPreferences.calendarEventCalendars()` |

The skip settings are `AgendaOptions.skipScheduledIfDone` / `skipDeadlineIfDone`, oracle-tested. With both nil (the default), done entries show only on their own date, as before. Both screens already apply them through `OrgPreferences.agendaOptions`.

`SKIPPED` in the user's files is not a TODO keyword: `org-todo-keywords` is `TODO PROJ LOOP STRT WAIT HOLD IDEA | DONE KILL` and the files have no `#+TODO`. Org shows such headings as plain past-scheduled entries too. Adding `SKIPPED` after the `|` makes it a done keyword, and the entries leave the agenda.

## Theme keys

New keys in `ThemeSpec.slots`, with light and dark defaults: `todo-next`, `todo-waiting`, `todo-cancelled` (with the existing `todo` and `done`), `priority-a`, `priority-b`, `priority-c` (others fall back to `priority`), `agenda-overdue`, `agenda-due-soon`, `agenda-event`. Today's header stays `agenda-today`. `[theme.category]` sets category colors by name, as `[theme.todo]` sets keyword colors.

Helpers on `ThemeSpec`:

- `TodoClass.of(keyword, isDone:)`: `next` for NEXT, STRT, STARTED, START, DOING, ACTIVE, INPROGRESS; `waiting` for WAIT, WAITING, HOLD, ONHOLD, BLOCKED, DEFERRED, SOMEDAY, MAYBE; `cancelled` for done keywords KILL, KILLED, CANCELLED, CANCELED, CANCEL, SKIPPED, SKIP, ABORTED, NO, WONTFIX; else `todo` / `done`.
- `todoColor(keyword, isDone:, dark:)`: `[theme.todo]` first, then the class key.
- `priorityColor(letter, dark:)`, `statusColor(status, dark:)` (`normal` uses `agenda-time`), `eventColor(event, dark:)`.
- `categoryColor(name, dark:)`: `[theme.category]`, else `categoryHue(name)` (FNV-1a of the UTF-8, mod 360, stable across runs) at HSL saturation 0.60 / lightness 0.40 in light, 0.65 / 0.70 in dark.

## Calendar events

`CalendarEvents` (`Sources/OrgApp/CalendarEvents.swift`) wraps `EKEventStore`:

- `requestAccess() async -> Bool` uses `requestFullAccessToEvents`. EventKit has no read-only level, so reading needs full access. `CalendarEvents.isAuthorized`.
- `events(from:to:chosen:) -> [AgendaEvent]` and `calendars()` for a picker.
- `CalendarEventRecord` is what conversion reads; `EKEvent` conforms, and tests use plain values.

`AgendaModel.calendarEvents` (nil reads none) and `calendarNames`: `refresh` fetches events for the agenda span into `AgendaModel.events`. The screens set both from the settings and call `requestAccess()` when `calendar-events` is on.

`NSCalendarsFullAccessUsageDescription` is in `ios/Orgstar/Info.plist`, `scripts/build-ios-app.sh` and `scripts/build-app.sh`. The Mac app is not sandboxed, so it needs no calendar entitlement.

## For the screen rebuilds

```swift
agenda.calendarEvents = OrgPreferences.calendarEvents() ? CalendarEvents() : nil  // keep one instance
agenda.calendarNames = OrgPreferences.calendarEventCalendars()
let groups = agenda.groups(showAllDates: OrgPreferences.agendaShowAllDates(), keep: filter.keeps)
for group in groups {
    // group.header / group.date(calendar:), group.isToday, group.isEmpty
    // group.overdue (today), group.rows, group.nowIndex(now:)
}
// row.gutter colored by theme.statusColor(row.status, dark:), icon by row.icon,
// category tint theme.categoryColor(row.category, dark:) or theme.eventColor(row.event!, dark:),
// keyword theme.todoColor(row.todo!, isDone: row.isDone, dark:), priority theme.priorityColor(_:dark:).
// Actions take row.item as before.
```

The TODO and match views (`agenda.list`) can use `AgendaRow(item:day:today:)` per item with `day: agenda.today`.
