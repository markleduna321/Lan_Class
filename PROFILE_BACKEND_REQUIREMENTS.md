# Profile & Community — Backend Requirements
**For the Web / Laravel Team**

Server base: `https://itcomm.asuratechsolutions.com`
Auth: Laravel Sanctum bearer tokens (`Authorization: Bearer {token}` + `Accept: application/json`)

This document covers the backend work needed for the **User Profile** and
**Community (Forum)** features: nicknames, bios, skills, projects, aura tiers,
and public profiles.

---

## Context

The mobile app now has:
- **Aura tiers**: Low (0–99), Advanced (100–999), High (1000+) — flame badge +
  name glow effects. Aura score already comes from `GET /api/forum/reputation`.
- **Profile showcase**: nickname, bio, skills (list), projects (list) — currently
  saved **locally only**.
- **Community author labels**: each post/response shows the author's **display
  name** (nickname → full name) with their aura tier effect, and is **tappable to
  open that user's public profile**.

To make these work across users (not just locally), the backend needs the fields
and endpoints below.

---

## 1. User model — new profile fields

Add these columns to the `users` table (all nullable):

```sql
ALTER TABLE users ADD COLUMN nickname VARCHAR(30)  NULL;
ALTER TABLE users ADD COLUMN bio      VARCHAR(280) NULL;
ALTER TABLE users ADD COLUMN skills   JSON         NULL;  -- ["Flutter","Laravel"]
ALTER TABLE users ADD COLUMN projects JSON         NULL;  -- [{title,description,link}]
```

- Add all four to the model's `$fillable`.
- `skills` and `projects` should be cast to `array` (`protected $casts`).
- **Aura**: the app treats the forum reputation score as the user's aura. Expose
  it as an `aura` attribute on the user (computed from votes — see §4) so it can
  be returned in profile responses.

`projects` item shape:
```json
{ "title": "My App", "description": "What it does", "link": "https://..." }
```

---

## 2. Self profile — GET & PATCH

### GET `/api/user/profile`
**Protected** — returns the authenticated user's full profile.

```json
// Response 200
{
  "id": 42,
  "name": "Juan Dela Cruz",
  "nickname": "juandev",
  "role": "student",
  "bio": "IT student who loves networking.",
  "aura": 150,
  "skills": ["Flutter", "Networking"],
  "projects": [
    { "title": "LAN Chat", "description": "A local chat app", "link": "https://github.com/..." }
  ]
}
```

### PATCH `/api/user/profile`
**Protected** — update editable profile fields. All fields optional; only send
what changed.

```json
// Request
{
  "nickname": "juandev",
  "bio": "IT student who loves networking.",
  "skills": ["Flutter", "Networking"],
  "projects": [
    { "title": "LAN Chat", "description": "A local chat app", "link": "https://github.com/..." }
  ]
}

// Response 200 — updated profile (same shape as GET)
```

> Validation: `nickname` ≤ 30 chars, `bio` ≤ 280 chars, each project `title` ≤ 60,
> `description` ≤ 200, `link` must be a valid URL when present.

---

## 3. Public profile — GET

### GET `/api/users/{id}/profile`
**Protected** — returns a **public** view of another user's profile. The app
opens this when a member taps an author in the community.

```json
// Response 200
{
  "id": 42,
  "name": "Juan Dela Cruz",
  "nickname": "juandev",
  "role": "student",
  "bio": "IT student who loves networking.",
  "aura": 150,
  "skills": ["Flutter", "Networking"],
  "projects": [
    { "title": "LAN Chat", "description": "A local chat app", "link": "https://github.com/..." }
  ]
}

// Response 404 — user not found
```

> The app **degrades gracefully** if this endpoint is missing (shows the name +
> aura it already knows from the post, with a "details unavailable" note). But the
> full showcase only appears once this endpoint ships.

---

## 4. Aura scoring (reputation)

`GET /api/forum/reputation` already returns the authenticated user's own score:

```json
{ "score": 150 }
```

**Aura definition (recommended):** net reputation earned across the user's forum
activity. When a vote is cast on a user's post/response, adjust that author's aura:

| Event | Author aura delta |
|---|---|
| Upvote received | **+5** |
| Downvote received | **−2** |
| Vote undone | reverse the above |

Store the running total on the user (e.g. `users.aura` or a cached column) so it
can be returned in profile responses (§2, §3) and embedded in forum lists (§5)
without recomputing.

Tier thresholds used by the app (for reference — no backend action needed):

| Tier | Range |
|---|---|
| Low | 0 – 99 |
| Advanced | 100 – 999 |
| High | 1000+ |

---

## 5. Forum lists — embed author identity  ⭐ IMPORTANT

So the community can render each author's **nickname** and **aura tier** without
making an extra request per post/response, include these fields on **every** post
and response object returned by the forum endpoints:

```json
{
  "id": "post-uuid",
  "...": "...existing fields...",
  "author_id": 42,
  "author_name": "Juan Dela Cruz",
  "author_nickname": "juandev",   // ← ADD  (null if not set)
  "author_aura": 150              // ← ADD  (author's current aura)
}
```

Apply to the response objects of:
- `GET /api/forum/posts` (each post)
- `GET /api/forum/posts/{id}` (the post **and** each item in `responses`)
- `POST /api/forum/posts` (returned `post`)
- `POST /api/forum/posts/{id}/responses` (returned `response`)

> The app already reads `author_nickname` and `author_aura` with safe fallbacks
> (`author_nickname → author_name`, `author_aura → 0`). Adding them lights up
> nicknames + tier flames/glows in the feed immediately.

---

## Summary Checklist

| # | Task | Endpoint / Table | Priority |
|---|------|------------------|----------|
| 1 | Add `nickname`, `bio`, `skills`, `projects` to `users` (+ `$fillable`, casts) | `users` | 🔴 Required |
| 2 | Expose `aura` attribute on user | `users` | 🔴 Required |
| 3 | `GET /api/user/profile` | self profile | 🔴 Required |
| 4 | `PATCH /api/user/profile` | update self | 🔴 Required |
| 5 | `GET /api/users/{id}/profile` | public profile | 🔴 Required |
| 6 | Add `author_nickname` + `author_aura` to all forum post/response payloads | forum endpoints | 🔴 Required |
| 7 | Aura scoring on votes (+5 / −2) with cached total | forum votes | 🟡 High |

---

## Notes for the App Team (internal)

- Once `PATCH /api/user/profile` exists, wire the profile editors (nickname, bio,
  skills, projects) to push to the server in addition to saving locally.
- Once forum payloads include `author_nickname` + `author_aura`, the community
  feed will automatically show nicknames and tier effects (no further app change
  needed — the reader already handles these fields).
- `GET /api/users/{id}/profile` unblocks the full public profile showcase
  (bio / skills / projects) that is already built and shipping with graceful
  fallback.
