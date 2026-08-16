# Course Academy — Real Data Plan (Future Work)

> **Status:** Deferred. This is the extracted **Phase 5** from `USER_PROFILE_PLAN.md`.
> Not scheduled yet — reference when we pick up the Academy work.

---

## Goal

Replace the hard-coded mock modules in
`lib/features/academy/course_timeline_view.dart` with **real, DB-backed**
course modules and **per-user progress tracking**, and connect academy
completion to the user profile metrics and achievement badges.

---

## Current State

- `course_timeline_view.dart` renders a **hard-coded** `_academyModules` list
  (OSI Model, Subnetting, VLAN, Firewall) with static `status`
  (`completed` / `active` / `locked`).
- No persistence — progress resets on every launch.
- No link to the user, aura, or profile metrics.

---

## Data Model

### New local table `academy_modules` (seeded on first run)
```sql
CREATE TABLE academy_modules (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  description TEXT,
  badge_name  TEXT,
  sort_order  INTEGER DEFAULT 0
);
```

### New local table `academy_progress`
```sql
CREATE TABLE academy_progress (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL,
  module_id     TEXT NOT NULL,
  status        TEXT NOT NULL,   -- locked | active | completed
  completed_at  TEXT,
  UNIQUE(user_id, module_id)
);
```

> DB version bump required (whatever the current version is at that time).
> Seed `academy_modules` with the existing 4 mock modules on `onCreate` /
> first migration so nothing looks empty.

---

## Repository Methods

- `getAcademyModules()` — ordered by `sort_order`.
- `getAcademyProgress(userId)` — map of `module_id → status`.
- `markModuleCompleted(userId, moduleId)` — set `completed`, unlock the next
  module (`active`), stamp `completed_at`.
- `getCompletedModuleCount(userId)` — for the profile metric.

---

## Progression Rules

1. First module starts `active`; the rest `locked`.
2. Completing an `active` module → `completed`, and the **next** `locked`
   module becomes `active`.
3. A `completed` module shows its earned badge (existing certificate dialog).
4. `locked` modules are non-interactive.

---

## UI Changes (`course_timeline_view.dart`)

- Load modules + progress from the DB instead of the mock list.
- Keep the existing timeline visual + certificate dialog.
- Add a "Mark Complete" action on the `active` module (or tie to a quiz/lesson
  completion if that flow is added later).
- Empty/error states.

---

## Profile Integration

- Profile "Academy Modules" metric card → real `getCompletedModuleCount`.
- Completing all modules → unlock a profile achievement badge
  (e.g. "Full-Stack Finisher").

---

## Optional Online Sync (later)

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/academy/modules` | `GET` | Server-defined module catalog (optional) |
| `/api/academy/progress` | `GET` | Fetch the user's progress |
| `/api/academy/progress` | `POST` | Push a completion event |

If online sync is added, treat the **server as source of truth** and cache
locally, mirroring how classrooms/materials work. Until then, Academy is
**fully offline** and per-device.

---

## Suggested Sub-Phases (when picked up)

1. **5a** — DB tables + seed + repository methods (invisible).
2. **5b** — Rewire `course_timeline_view.dart` to DB data + completion action.
3. **5c** — Profile metric + achievement badge integration.
4. **5d** — (Optional) online sync.
