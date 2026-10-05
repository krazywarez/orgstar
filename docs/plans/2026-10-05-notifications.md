# Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Local notifications before timed agenda entries, as `org-agenda-to-appt` and appt give in Emacs, kept in step with the files and shown in the agenda.

**Architecture:** `OrgCore/Agenda/Reminders.swift` turns the next days of the agenda into reminders: entries with a time of day (scheduled, deadline, timestamp, range start), not done, fired `APPT_WARNTIME` or the lead time before. `ReminderScheduler` in OrgApp reconciles them with the pending requests of a `NotificationCenter` (the real one wraps `UNUserNotificationCenter`; tests use a fake): removes what no longer applies, adds what's new, keeps at most 64 (the iOS cap). The app reconciles at launch, on file changes and on edits, and hourly. Clicking a notification jumps to the entry. The agenda window says how far ahead reminders are set.

**Tech Stack:** Swift 6.2 tools, Swift Testing, UserNotifications.

**Spec:** `docs/design.md`, "Phase 3", risks table ("Notifications").

## Global Constraints

- Notifications need the app bundle (`scripts/build-app.sh`); an unbundled debug binary skips them.
- Request IDs start with `orgstar.`; other requests are left alone.

## Defaults chosen (user may change)

- On, 12 minutes before (appt's `appt-message-warning-time`), 7 days ahead.

---

### Task 1: Reminders

- [x] `Reminders.upcoming`; `AgendaItem.warntime`; tests for leads, `APPT_WARNTIME`, done entries, ranges, the cap, entries already past.
- [x] `ReminderScheduler` with a fake center: adds, removes, keeps, reports the horizon.
- [x] App: settings, reconcile triggers, click to jump, agenda footer.
- [x] Commit "Notifications".
