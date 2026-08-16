# User Profile & Progression System — Implementation Plan

> Goal: Replace all hard-coded profile / aura / academy data with **real data**
> sourced from the local SQLite DB (offline) and the Laravel backend (online),
> add an **Aura tier system**, **nicknames**, **public profiles**, and a
> **skills/projects showcase**.

---

## Current State (what exists today)

| Area | File | Status |
|---|---|---|
| Profile screen | `lib/features/classroom/user_profile_view.dart` | **Hard-coded** names, "Community Aura", metrics, badges. Cloud link/unlink logic is real. |
| Community aura | `lib/features/forum/forum_workspace_view.dart` | Shows "Community Reputation … Aura" from `GET /api/forum/reputation`. |
| Community posts | `lib/features/forum/*` | Show raw `author_name`. No nickname, no tier badge, no profile view. |
| Course Academy | `lib/features/academy/course_timeline_view.dart` | **Hard-coded** mock modules. No DB tracking. |
| Users table | `lib/database/asura_db.dart` (v15) | Has `aura_score` (unused), no `nickname` / `bio` / `skills` / `projects`. |
| Repository | `lib/database/asura_repository.dart` | `getUserById`, `getUserByEmail`, `validateLogin`, `updateUserRemoteId`. No profile-update methods. |

---

## Aura Tier Specification

| Tier | Aura range | Flame badge | Name effect |
|---|---|---|---|
| **Low** | `0 – 99` | 🔥 Orange flame | None (plain text) |
| **Advanced** | `100 – 999` | 🔥 Red flame | Red glow around the name |
| **High** | `1000+` | 🔥 Purple flame | Name glow **+** animated fire/shimmer effect |

- The tier badge + name effect appear **everywhere a user's identity is shown**:
  profile hero card, community post authors, response authors, and public profiles.
- **Display name precedence:** `nickname` → falls back to full name if nickname is empty.

---

## Data Model Changes

### Local `users` table (DB v15 → v16)
Add columns:
```sql
ALTER TABLE users ADD COLUMN nickname   TEXT;
ALTER TABLE users ADD COLUMN bio        TEXT;
ALTER TABLE users ADD COLUMN skills     TEXT;   -- JSON array:  ["Flutter","Laravel"]
ALTER TABLE users ADD COLUMN projects   TEXT;   -- JSON array of {title,description,link}
-- aura_score already exists (INTEGER DEFAULT 0)
```

### New local `academy_progress` table (Phase 5)
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

---

## Phases

### Phase 1 — Data Foundation  ✅ DONE
**Deliverables**
- DB migration v15 → v16 (nickname, bio, skills, projects). ✅
- Repository methods: `getActiveUser()`, `updateUserProfile()`, `updateAuraScore()`. ✅
- `aura_score` + profile columns added to `users` CREATE TABLE + migration. ✅
- Online profile sync (`CloudApiService`) deferred until backend endpoints exist.

---

### Phase 2 — Aura Tier System (shared widgets)  ✅ DONE
**Deliverables**
- New file `lib/features/shared/aura.dart`: ✅
  - `enum AuraTier { low, advanced, high }` + `auraTierFor(score)`.
  - `AuraFlameBadge(score)` — orange/red/purple flame widget.
  - `AuraName(name, score)` — plain / red-glow / glow+animated-fire shimmer.
  - `resolveDisplayName(user)` — nickname → full name fallback helper.
- Renamed **"Community Reputation" → tier label + "Aura"** in the forum banner. ✅
- Renamed **"Community Aura" → "Aura"** + flame badge + tier in the profile chip. ✅

---

### Phase 3 — Real Profile (self)  ✅ DONE
**Deliverables** (`user_profile_view.dart` rewrite)
- Real name / role / avatar initials from the DB (`getActiveUser`). ✅
- `AuraName` + `AuraFlameBadge` using the real aura (online reputation → local cache fallback). ✅
- **Nickname editor** — inline edit next to the display name; saved to DB. ✅
- **Bio** ("About") section — editable. ✅
- **Skills** showcase — chip list with add / remove. ✅
- **Projects** showcase — cards `{title, description, link}` with add / edit / delete. ✅
- Real metric cards (Classrooms, Aura Tier, Skills count, Projects count). ✅
- Achievements now unlock from real aura (100+ / 1000+). ✅
- Cloud Account link/unlink section kept as-is. ✅

> Online profile **sync** of nickname/bio/skills/projects (`PATCH /api/user/profile`)
> is deferred to Phase 4 backend work — currently saved locally.

---

### Phase 4 — Community Integration  ✅ DONE (client) · ⏳ backend pending
**Deliverables**
- Posts & responses show the **display name** (nickname → full name) via
  `ForumAuthorLabel` with `AuraName` effect + `AuraFlameBadge`. ✅
- Forum banner shows the user's own tier + flame badge. ✅ (Phase 2)
- **Tap an author → open their public profile** (read-only). ✅
- New `PublicProfileView` — nickname, aura tier, bio, skills, projects, with
  graceful fallback when the backend endpoint is missing. ✅
- Reader handles `author_nickname` + `author_aura` with safe fallbacks
  (`author_name` / `0`) so it lights up automatically once the backend sends them. ✅

**Backend requirements documented in `PROFILE_BACKEND_REQUIREMENTS.md`:**
- `GET/PATCH /api/user/profile`, `GET /api/users/{id}/profile`
- `author_nickname` + `author_aura` on all forum post/response payloads
- Aura scoring (+5 / −2) on votes

---

### Phase 5 — Course Academy Real Data  → moved out
Extracted to its own deferred plan: **`COURSE_ACADEMY_PLAN.md`**.
Not scheduled with this batch of work.

---

## Backend Requirements Summary

> A separate detailed file (`PROFILE_BACKEND_REQUIREMENTS.md`) will be produced
> when Phase 1/4 implementation starts. High-level needs:

| Endpoint | Method | Purpose | Phase |
|---|---|---|---|
| `/api/user/profile` | `GET` | Full self profile (nickname, bio, skills, projects, aura) | 1 |
| `/api/user/profile` | `PATCH` | Update nickname, bio, skills, projects | 1, 3 |
| `/api/users/{id}/profile` | `GET` | **Public** profile of another user | 4 |
| `/api/forum/posts` (response shape) | — | Include `author_nickname`, `author_aura` per post/response | 4 |
| `/api/academy/progress` | `GET`/`POST` | Sync module progress (optional) | 5 |

DB (Laravel `users` table): add `nickname`, `bio`, `skills` (JSON), `projects` (JSON).
Ensure all are in `$fillable` and serialized.

---

## Recommended Rollout Order

1. **Phase 1** (data layer) — safe, invisible, unblocks everything.
2. **Phase 2** (aura widgets + rename) — small, high-visibility quick win.
3. **Phase 3** (real self-profile + nickname + showcase).
4. **Phase 4** (community nickname/tier + public profiles).
5. **Phase 5** (academy real data).

Each phase is independently shippable and leaves the app in a working state.
