# AsuraTECH LAN Classroom — Backend API Specification
**For the Web / Laravel Team**

**Updated:** 2026-08-08 — user roles and reputation contract

Server base: `https://itcomm.asuratechsolutions.com`  
Auth: Laravel Sanctum bearer tokens  
All protected endpoints require: `Authorization: Bearer {token}` + `Accept: application/json`

---

## Global Conventions

| Rule | Detail |
|---|---|
| Date format | ISO 8601 — `2026-07-12T10:00:00.000000Z` |
| IDs | UUID strings preferred; integers accepted |
| Pagination | Wrap arrays in `{"data": [...], "meta": {...}}` or return flat arrays |
| Errors | `{"message": "Human-readable error"}` with appropriate HTTP status |
| 204 responses | Acceptable for destructive actions (delete, end, logout) |

### User roles

| Role | Meaning |
|---|---|
| `student` | Default account role for classroom participants |
| `teacher` | Account role for classroom presenters and owners |

Account roles are separate from session join roles such as `moderator` and `participant`.
Submitting any other account role returns `422 Unprocessable Entity`.

---

## 1. Authentication

### POST `/api/auth/register`
**Public**

```json
// Request
{
  "name": "Juan Dela Cruz",
  "email": "juan@example.com",
  "role": "student",
  "password": "Secret123!",
  "password_confirmation": "Secret123!"
}

// role is optional and defaults to "student"

// Response 201
{
  "user": {
    "id": 1,
    "name": "Juan Dela Cruz",
    "email": "juan@example.com",
    "role": "student",
    "reputation": 0,
    "email_verified_at": null,
    "created_at": "2026-08-08T10:00:00.000000Z",
    "updated_at": "2026-08-08T10:00:00.000000Z"
  },
  "token": "1|sanctum-token-here"
}

// Response 422 — unsupported role
{
  "message": "The selected role is invalid.",
  "errors": { "role": ["The selected role is invalid."] }
}
```

### POST `/api/auth/login`
**Public**

```json
// Request
{ "email": "juan@example.com", "password": "Secret123!" }

// Response 200
{
  "user": {
    "id": 1,
    "name": "Juan Dela Cruz",
    "email": "juan@example.com",
    "role": "student",
    "reputation": 12,
    "email_verified_at": null,
    "created_at": "2026-08-08T10:00:00.000000Z",
    "updated_at": "2026-08-08T10:00:00.000000Z"
  },
  "token": "1|sanctum-token-here"
}

// Response 422 — validation / wrong credentials
{ "message": "The provided credentials are incorrect." }
```

### POST `/api/auth/logout`
**Protected** → `204 No Content`

### GET `/api/user`
**Protected**

```json
// Response 200
{
  "id": 1,
  "name": "Juan Dela Cruz",
  "email": "juan@example.com",
  "role": "student",
  "reputation": 12,
  "email_verified_at": null,
  "created_at": "2026-08-08T10:00:00.000000Z",
  "updated_at": "2026-08-08T10:00:00.000000Z"
}
```

`role` cannot be changed through the ordinary `PUT /api/user` or profile update endpoints.

### GET `/api/user/profile`
**Protected** — returns the authenticated user's extended profile.

```json
// Response 200
{
  "id": 1,
  "name": "Juan Dela Cruz",
  "display_name": "Juan Dela Cruz",
  "bio": null,
  "skills": [],
  "projects": [],
  "role": "student",
  "reputation": 12,
  "aura": 12,
  "email": "juan@example.com"
}
```

`aura` is retained as a backward-compatible alias of `reputation` in profile responses.

---

## 2. Classrooms

### GET `/api/classrooms`
**Public** — returns ALL published classrooms.

```
Query params:
  search      (optional) — partial name search
  visibility  (optional) — "public" | "private"  ← REQUIRED for filtering
```

The Flutter app sends `GET /api/classrooms?visibility=public` from the student browser.  
**Please implement server-side filtering** so private rooms are excluded from this list.

```json
// Response 200 — array or paginated
[
  {
    "id": "classroom-uuid",
    "name": "Networking 101",
    "description": "Basic networking class",
    "schedule": "Mon-Fri 1pm-3pm",
    "visibility": "public",
    "teacher_name": "Mark Harvey",
    "is_active": false
  }
]
```

### GET `/api/classrooms/{id}`
**Public** — fetch a single classroom by ID (used for private room lookup by room ID).

```json
// Response 200
{ "id": "...", "name": "...", "schedule": "...", "visibility": "private", "teacher_name": "..." }
// Response 404 — room not found
```

### POST `/api/classrooms`
**Protected** — teacher publishes a classroom.

```json
// Request
{
  "id": "local-uuid",
  "name": "Networking 101",
  "description": "Basic networking class",
  "schedule": "Mon-Fri 1pm-3pm",
  "visibility": "public"   // ← MUST be stored and returned
}

// Response 201
{ "id": "local-uuid", "name": "Networking 101", ... }
```

> ⚠️ **QA CONFIRMED (2026-07-13):** A live publish request with `"visibility":"public"`
> returned a response with **NO `visibility` field**. Verified response was:
> ```json
> {"id":"...","owner_id":6,"owner_name":"QA Tester","name":"QA Room",
>  "description":"qa","schedule":"now","material_count":0,"materials":[],
>  "active_session":null,"created_at":"...","updated_at":"..."}
> ```
> The `visibility` field MUST be added to the model's `$fillable` array, stored in
> the DB, and serialized in **all** classroom responses (`POST`, `GET /api/classrooms`,
> `GET /api/classrooms/{id}`). Until this is fixed, private rooms leak into the
> public student browser.

### PUT `/api/classrooms/{id}`
**Protected** — update classroom details (name, description, schedule, visibility).

### DELETE `/api/classrooms/{id}`
**Protected** → `204 No Content`

### GET `/api/classrooms/{id}/materials`
**Public** — returns materials list.

```json
// Response 200
[
  {
    "id": "material-uuid",
    "original_name": "Lecture_1.pdf",
    "mime_type": "application/pdf",
    "url": "https://itcomm.asuratechsolutions.com/storage/materials/...",
    "file_url": "https://..."    // alias accepted
  }
]
```

### POST `/api/classrooms/{id}/materials`
**Protected** — multipart file upload.

> ⚠️ **QA FINDING (2026-07-13):** The current backend validation requires
> `id`, `mime_type`, and `size_bytes` in addition to the file. The Flutter app
> has been updated to send all of these. **Please confirm these remain required**,
> or make `id` / `size_bytes` optional (the server can derive `size_bytes` from
> the uploaded file and generate `id` server-side). Document the final contract here.

```
Multipart form fields:
  file          (binary)  — REQUIRED — the uploaded file
  id            (string)  — REQUIRED — client-generated material UUID
  original_name (string)  — REQUIRED — original filename
  mime_type     (string)  — REQUIRED — e.g. "application/pdf"
  size_bytes    (integer) — REQUIRED — file size in bytes
```

```json
// Response 201 — VERIFIED live response shape
{
  "id": "material-uuid",
  "classroom_id": "classroom-uuid",
  "original_name": "Lecture_1.pdf",
  "filename": "material-uuid.pdf",
  "mime_type": "application/pdf",
  "size_bytes": 34,
  "file_url": "https://itcomm.asuratechsolutions.com/storage/materials/.../material-uuid.pdf",
  "created_at": "2026-07-13T13:07:36.000000Z",
  "updated_at": "2026-07-13T13:07:36.000000Z"
}
```

> 📌 The response uses **`file_url`** (not `url`). The Flutter parser accepts both.
> If you standardise on one key, prefer `file_url`.


### DELETE `/api/classrooms/{id}/materials/{mid}`
**Protected** → `204 No Content`

### GET `/api/classrooms/{id}/active-session`
**Public ← CRITICAL** — students poll this every 6 seconds.

```json
// Response 200 — session is live
{
  "id": "session-uuid",
  "status": "active",
  "channel": "session.session-uuid",
  "ws_url": "legacy-only",
  "current_quiz": null,     // or quiz object when teacher broadcasts
  "current_slide": null,    // or slide object when teacher presents
  "hand_queue": [],
  "participant_count": 5
}

// Response 404 — no active session
```

> ⚠️ **Important:** This endpoint is the ONLY way students know if a session is live. It replaces Reverb WebSocket for session state. Students poll it every 6 seconds.

> 📌 **For quiz/slide delivery:** When the teacher broadcasts `QUIZ_START` or `SLIDE_START` via `POST /api/sessions/{id}/broadcast`, store the event data in the session record. Return it in the `current_quiz` / `current_slide` fields above so students receive it on the next poll cycle.

### POST `/api/classrooms/{id}/join`
**Protected** — student registers as a participant.

```json
// Response 200
{
  "message": "Joined classroom successfully.",
  "session": {
    "id": "session-uuid",
    "status": "active",
    "channel": "session.session-uuid",
    "ws_url": "legacy-only",
    "room_name": "session-session-uuid",
    "participant_count": 6
  }
}
```

---

## 3. Sessions (Teacher)

### POST `/api/sessions`
**Protected** — teacher starts a live session.

```json
// Request
{ "classroom_id": "classroom-uuid" }

// Response 201
{
  "id": "session-uuid",
  "classroom_id": "classroom-uuid",
  "status": "active",
  "channel": "session.session-uuid",
  "ws_url": "legacy-only",
  "room_name": "session-session-uuid",
  "started_at": "2026-07-12T10:00:00.000000Z"
}
```

### POST `/api/sessions/{id}/end`
**Protected** → `200` or `204`

> When a session is ended, `GET /api/classrooms/{id}/active-session` must return 404.

### GET `/api/sessions/{id}`
**Protected** — returns session details including hand queue.

```json
// Response 200
{
  "id": "session-uuid",
  "status": "active",
  "hand_queue": [
    { "student_id": "42", "student_name": "Juan", "raised_at": "..." }
  ],
  "participant_count": 8
}
```

### GET `/api/sessions/{id}/participants`
**Protected**

```json
// Response 200
[
  { "id": 1, "name": "Juan Dela Cruz", "joined_at": "2026-07-12T10:05:00Z" }
]
```

### POST `/api/sessions/{id}/broadcast`
**Protected** — teacher pushes an event to all students.

```json
// Request
{
  "event": "QUIZ_START",
  "data": {
    "quiz_id": "quiz-uuid",
    "quiz_title": "Chapter 1 Quiz",
    "time_limit": 300,
    "questions": [
      {
        "id": "q1",
        "text": "What is a MAC address?",
        "type": "multiple_choice",
        "options": ["A unique hardware identifier", "An IP address", "A domain name", "A port number"]
      }
    ]
  }
}
// Response 200
```

> ⚠️ **Critical:** When `event == "QUIZ_START"`, store `data` in `sessions.current_quiz`.  
> When `event == "SLIDE_START"`, store `data` in `sessions.current_slide`.  
> When `event == "QUIZ_ENDED"` or `"PRESENTATION_ENDED"`, clear the respective field.  
> This allows students to receive events via polling.

### POST `/api/sessions/{id}/join`
**Protected** — returns Jitsi room data for video call.

```json
// Response 200
{
  "session_id": "session-uuid",
  "provider": "jitsi",
  "room_name": "session-session-uuid",
  "room_url": "https://meet.jit.si/session-session-uuid",
  "role": "participant",
  "display_name": "Juan Dela Cruz",
  "subject": "Networking 101",
  "jwt": null,
  "jaas": { "app_id": null, "require_jwt": false }
}
```

---

## 4. Quiz

### POST `/api/sessions/{id}/quiz/submit`
**Protected**

```json
// Request
{
  "student_id": "42",
  "student_name": "Juan Dela Cruz",
  "quiz_id": "quiz-uuid",
  "quiz_title": "Chapter 1 Quiz",
  "answers": [
    { "question_id": "q1", "answer": "A unique hardware identifier" }
  ]
}
// Response 200
{ "message": "Quiz submitted." }
```

### GET `/api/sessions/{id}/quiz/results`
**Protected (teacher)**

```json
// Response 200
[
  {
    "student_name": "Juan Dela Cruz",
    "score": 8,
    "total": 10,
    "submitted_at": "2026-07-12T10:30:00Z"
  }
]
```

---

## 5. Chat

### GET `/api/sessions/{id}/chat`
**Protected**

```json
// Response 200
[
  {
    "id": "msg-uuid",
    "sender_id": "42",
    "sender_name": "Juan",
    "is_teacher": false,
    "body": "Hello class",
    "sent_at": "2026-07-12T10:05:00Z"
  }
]
```

### POST `/api/sessions/{id}/chat`
**Protected**

```json
// Request
{
  "sender_id": "42",
  "sender_name": "Juan Dela Cruz",
  "is_teacher": false,
  "body": "Hello class"
}
// Response 201
{ "id": "msg-uuid", "body": "Hello class", ... }
```

---

## 6. Hand Raise

### POST `/api/sessions/{id}/hand/raise`
**Protected**

```json
// Request
{ "student_id": "42", "student_name": "Juan Dela Cruz" }
// Response 200
```

### POST `/api/sessions/{id}/hand/lower`
**Protected**

```json
// Request
{ "student_id": "42" }
// Response 200
```

### POST `/api/sessions/{id}/hand/call`
**Protected (teacher)** — calls on a specific student.

```json
// Request
{ "student_id": "42" }
// Response 200
```

> When a student is called on, the session's `active-session` endpoint should include
> `"called_on": "42"` so the polling student sees the CALLED_ON event.

---

## 7. AI Helper (Temporary Session Chat)

### POST `/api/ai-helper`
**Protected**

This endpoint powers the Flutter AI Helper and should be used instead of calling OpenAI directly from the mobile app.

```json
// Request
{
  "prompt": "Explain the lesson about networking",
  "materials": [
    {
      "classroom_id": "classroom-uuid",
      "classroom_name": "Networking 101",
      "original_name": "Lecture 1.pdf",
      "mime_type": "application/pdf",
      "material_id": "material-uuid",
      "storage_path": "/storage/materials/lecture-1.pdf",
      "download_url": "https://itcomm.asuratechsolutions.com/storage/materials/lecture-1.pdf"
    }
  ],
  "studentMaterials": [],
  "conversationHistory": [
    {
      "role": "user",
      "content": "Show me the available materials"
    },
    {
      "role": "assistant",
      "content": "I found Lecture 1.pdf"
    }
  ],
  "allowWebSearch": false
}
```

```json
// Response 200
{
  "reply": "A classroom-grounded answer here"
}
```

### Backend requirements

- Read the OpenAI key from the web server environment only (for example `.env` as `OPENAI_API_KEY`).
- Do not expose the OpenAI key to the Flutter client.
- The assistant must remain grounded to the provided classroom materials.
- For each material entry, resolve the actual material content from the server-side storage or download URL before sending it to the model.
- If the material is a PDF, text document, or supported text-based file, extract or read the text content server-side before prompting the model.
- If the material cannot be read, return a short fallback reply such as: “I could not read the attached material yet.”
- If the prompt is unrelated to the materials, return a short refusal-style reply instead of answering general questions.
- If `allowWebSearch` is `true`, allow only a minimal supplemental relevance note and keep the answer focused on the classroom context.
- This feature is temporary and session-only. The backend should not persist chat history in the database.
- The Flutter client will manage the conversation state in memory and clear it when the session ends or the user signs out.

### Notes

- The backend should treat this as a lightweight AI proxy endpoint.
- The Flutter app should call this route rather than calling OpenAI directly.
- No shared API key should be exposed in the app UI or returned by any API response.

---

## 7. Community Forum

All forum endpoints are **Protected** (require Sanctum token).

---

### GET `/api/forum/posts`
**Protected**

```
Query params:
  category  (optional) — "question" | "poll" | "showcase"
  page      (optional) — for pagination
```

```json
// Response 200
{
  "data": [
    {
      "id": "post-uuid",
      "category": "question",
      "title": "How does inter-VLAN routing work?",
      "body": "I am setting up a lab...",
      "author_name": "Mark Harvey",
      "author_id": 1,
      "code_snippet": null,
      "link": null,
      "poll_options": null,
      "user_poll_vote": null,
      "vote_score": 42,
      "user_vote": 0,
      "response_count": 3,
      "created_at": "2026-07-12T08:00:00Z"
    }
  ],
  "meta": { "current_page": 1, "total": 25 }
}
```

**`vote_score`** = total upvotes − total downvotes  
**`user_vote`** = -1, 0, or 1 for the authenticated user  
**`user_poll_vote`** = option ID voted by the authenticated user, or null

For **Poll** posts, `poll_options` contains:

```json
"poll_options": [
  { "id": "opt-1", "text": "Option A", "votes": 15 },
  { "id": "opt-2", "text": "Option B", "votes": 8  }
]
```

---

### POST `/api/forum/posts`
**Protected**

```json
// Request
{
  "category": "question",
  "title": "How does inter-VLAN routing work?",
  "body": "I am setting up a lab for my students...",
  "author_name": "Mark Harvey",
  "author_id": 1,
  "code_snippet": "ip route 192.168.1.0 255.255.255.0 ...",
  "link": "https://docs.sophos.com/...",
  "poll_options": null
}

// For Poll type:
{
  "category": "poll",
  "title": "Which OS is better for networking labs?",
  "body": "Curious about preferences.",
  "poll_options": ["Ubuntu", "Windows Server", "pfSense"]
}

// Response 201
{
  "post": {
    "id": "post-uuid",
    "category": "question",
    "title": "...",
    "vote_score": 0,
    "user_vote": 0,
    "response_count": 0,
    ...
  }
}
```

---

### GET `/api/forum/posts/{id}`
**Protected** — returns post + all responses.

```json
// Response 200
{
  "post": {
    "id": "post-uuid",
    ...all fields from list...,
    "responses": [
      {
        "id": "resp-uuid",
        "body": "You should use router-on-a-stick...",
        "code_snippet": null,
        "author_name": "Pedro Santos",
        "vote_score": 5,
        "user_vote": 0,
        "created_at": "2026-07-12T08:10:00Z"
      }
    ]
  }
}
```

---

### POST `/api/forum/posts/{id}/vote`
**Protected** — upvote / downvote / undo.

```json
// Request
{ "vote": 1 }   // 1 = upvote, -1 = downvote, 0 = undo

// Response 200
{ "vote_score": 43, "user_vote": 1 }
```

> **Reputation update:** After every post vote or vote removal, the server recalculates
> the author's reputation across all votes received on both posts and responses, then
> persists the result in `users.forum_reputation`. Upvote = +1, downvote = −1, and
> undo (`vote: 0`) removes that vote's contribution.

---

### POST `/api/forum/posts/{id}/poll-vote`
**Protected** — vote for a poll option.

```json
// Request
{ "option_id": "opt-1" }
// Response 200
{ "user_poll_vote": "opt-1", "poll_options": [...updated votes...] }
```

---

### POST `/api/forum/posts/{id}/responses`
**Protected**

```json
// Request
{
  "body": "You should use router-on-a-stick architecture...",
  "code_snippet": "interface GigabitEthernet0/0.10\n  encapsulation dot1Q 10",
  "author_name": "Pedro Santos",
  "author_id": 2
}

// Response 201
{
  "response": {
    "id": "resp-uuid",
    "body": "You should use router-on-a-stick...",
    "code_snippet": "...",
    "author_name": "Pedro Santos",
    "vote_score": 0,
    "user_vote": 0,
    "created_at": "2026-07-12T08:10:00Z"
  }
}
```

---

### POST `/api/forum/posts/{id}/responses/{rid}/vote`
**Protected**

```json
// Request
{ "vote": 1 }
// Response 200
{ "vote_score": 6, "user_vote": 1 }
```

Response votes use the same reputation recalculation and persistence behavior as post votes.

---

### GET `/api/forum/reputation`
**Protected** — returns the authenticated user's forum reputation.

```json
// Response 200
{ "score": 150 }
```

> `score` = sum of all votes received on the user's posts + responses (upvote = +1, downvote = −1).
> The same value is exposed as `reputation` in authentication/user responses and as
> both `reputation` and the backward-compatible `aura` field in profile responses.

---

## 8. Required Database Schema Changes

### `users` table

```sql
ALTER TABLE users ADD COLUMN role VARCHAR(20) NOT NULL DEFAULT 'student';
CREATE INDEX users_role_index ON users(role);
```

Allowed application values are `student` and `teacher`. The existing
`forum_reputation` integer stores the recalculated reputation score and defaults to `0`.

### `classrooms` table
Add column if not present:
```sql
ALTER TABLE classrooms ADD COLUMN visibility VARCHAR(20) DEFAULT 'public';
```
> **Ensure this column is in `$fillable` and serialized in `toArray()`.**

### `sessions` table
Add columns for polling-based event delivery:
```sql
ALTER TABLE sessions ADD COLUMN current_quiz JSON NULL;
ALTER TABLE sessions ADD COLUMN current_slide JSON NULL;
```

### `forum_posts` table (NEW)
```sql
CREATE TABLE forum_posts (
  id           CHAR(36)     PRIMARY KEY,
  category     ENUM('question','poll','showcase') NOT NULL,
  title        VARCHAR(200) NOT NULL,
  body         TEXT         NULL,
  code_snippet TEXT         NULL,
  link         VARCHAR(500) NULL,
  author_id    BIGINT       NOT NULL,
  author_name  VARCHAR(100) NOT NULL,
  created_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE CASCADE
);
```

### `forum_poll_options` table (NEW)
```sql
CREATE TABLE forum_poll_options (
  id         CHAR(36)    PRIMARY KEY,
  post_id    CHAR(36)    NOT NULL,
  text       VARCHAR(200) NOT NULL,
  votes      INT         DEFAULT 0,
  FOREIGN KEY (post_id) REFERENCES forum_posts(id) ON DELETE CASCADE
);
```

### `forum_votes` table (NEW)
```sql
CREATE TABLE forum_votes (
  id           BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id      BIGINT      NOT NULL,
  votable_type ENUM('post','response') NOT NULL,
  votable_id   CHAR(36)    NOT NULL,
  vote         TINYINT     NOT NULL DEFAULT 0,  -- 1, -1, or 0
  created_at   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY   uq_user_votable (user_id, votable_type, votable_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

### `forum_responses` table (NEW)
```sql
CREATE TABLE forum_responses (
  id           CHAR(36)    PRIMARY KEY,
  post_id      CHAR(36)    NOT NULL,
  body         TEXT        NOT NULL,
  code_snippet TEXT        NULL,
  author_id    BIGINT      NOT NULL,
  author_name  VARCHAR(100) NOT NULL,
  created_at   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (post_id)   REFERENCES forum_posts(id) ON DELETE CASCADE,
  FOREIGN KEY (author_id) REFERENCES users(id)       ON DELETE CASCADE
);
```

### `forum_poll_user_votes` table (NEW)
```sql
CREATE TABLE forum_poll_user_votes (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id    BIGINT      NOT NULL,
  post_id    CHAR(36)    NOT NULL,
  option_id  CHAR(36)    NOT NULL,
  UNIQUE KEY uq_poll_vote (user_id, post_id),
  FOREIGN KEY (user_id)   REFERENCES users(id)              ON DELETE CASCADE,
  FOREIGN KEY (post_id)   REFERENCES forum_posts(id)        ON DELETE CASCADE,
  FOREIGN KEY (option_id) REFERENCES forum_poll_options(id) ON DELETE CASCADE
);
```

---

## 9. Priority Order

| Priority | Issue | Impact |
|---|---|---|
| 🔴 Critical | `visibility` not stored/returned on classrooms (QA-confirmed) → private rooms visible to all | Security |
| 🔴 Critical | Material upload requires `id` + `mime_type` + `size_bytes` — undocumented (QA-confirmed) | Uploads failed |
| 🔴 Critical | `current_quiz` / `current_slide` not stored on broadcast → students never receive quiz | Core feature broken |
| 🟡 High | `GET /api/classrooms/{id}/active-session` must return `hand_queue` and `current_quiz` | Student polling |
| 🟡 High | Session `called_on` field in active-session response | Hand raise |
| 🟢 Normal | Standardise material response key on `file_url` (currently returns `file_url`, not `url`) | Consistency |
| 🟢 Normal | Pagination on `GET /api/forum/posts` | Performance |

> **Material upload — RESOLVED on Flutter side (2026-07-13):** The app now sends
> `id`, `original_name`, `mime_type`, and `size_bytes` alongside the `file`. Live QA
> upload now returns 201. Web team only needs to confirm/document that these fields
> stay required (or relax them).

---

## 10. Response Header Requirements

All responses must include:
```
Content-Type: application/json
Access-Control-Allow-Origin: *   (or specific app domain)
```

CORS must be enabled for the mobile app's HTTP requests.
