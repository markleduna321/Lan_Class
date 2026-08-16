# AsuraTECH LAN Classroom — Laravel + Reverb Server Phases

## How to Use This File
- Mirror of `ONLINE_PHASES.md` from the Flutter side — each phase here corresponds to one there.
- Complete each phase in order; the Flutter app will not function for a phase until its API endpoints are live.
- Update the **Status** column as each phase is deployed and tested.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Laravel 11+ |
| Database | MySQL 8+ |
| Auth | Laravel Sanctum (Bearer token) |
| WebSocket | Laravel Reverb (Pusher protocol) |
| File Storage | `storage/app/public` (local) or S3 |
| Queue | `database` driver (or Redis in production) |

---

## Phase Status

| Phase | Title | Status |
|---|---|---|
| 1 | Account Linking & API Client | ⬜ Pending |
| 2 | Publish Classrooms & Sync Materials | ⬜ Pending |
| 3 | Online Classroom Browser (Student) | ⬜ Pending |
| 4 | Online Live Session (WebSocket) | ⬜ Pending |
| 5 | WebRTC Signaling Channel | ⬜ Pending |
| 6 | Online Quiz & Chat | ⬜ Pending |
| 7 | Raise Hand & Participant Control | ⬜ Pending |
| 8 | Hybrid Session Bridge | ⬜ Pending |

---

## Global Conventions

### Authentication
All protected routes use Sanctum Bearer token.

```
Authorization: Bearer <token>
```

Token is issued on login/register and stored by the Flutter app in `flutter_secure_storage` under the key `ONLINE_TOKEN`.

### Response Envelope
Wrap list responses in a `data` key for forward compatibility:
```json
{ "data": [ ... ] }
```
Single-object responses can be returned flat:
```json
{ "id": 1, "name": "..." }
```

### Error Responses
```json
{ "message": "Human-readable error", "errors": { "field": ["detail"] } }
```
Use standard HTTP status codes: `400` validation, `401` unauthenticated, `403` forbidden, `404` not found, `409` conflict, `422` unprocessable, `500` server error.

### Base URL
All routes are prefixed with `/api`. Example: `https://api.yourdomain.com/api/auth/login`.

---

## Database Overview

### Core Tables

```sql
users
  id              BIGINT PK AUTO_INCREMENT
  name            VARCHAR(255)
  email           VARCHAR(255) UNIQUE
  password        VARCHAR(255)
  remember_token  VARCHAR(100) NULL
  created_at      TIMESTAMP
  updated_at      TIMESTAMP

personal_access_tokens   -- Sanctum; auto-managed

classrooms
  id              VARCHAR(36) PK  -- UUID from Flutter
  owner_id        BIGINT FK → users.id
  name            VARCHAR(255)
  description     TEXT NULL
  schedule        VARCHAR(255) NULL
  created_at      TIMESTAMP
  updated_at      TIMESTAMP

materials
  id              VARCHAR(36) PK  -- UUID from Flutter
  classroom_id    VARCHAR(36) FK → classrooms.id
  original_name   VARCHAR(255)
  filename        VARCHAR(255)    -- stored filename
  mime_type       VARCHAR(100)
  size_bytes      BIGINT
  file_url        VARCHAR(500)    -- publicly accessible URL
  created_at      TIMESTAMP
  updated_at      TIMESTAMP

sessions
  id              VARCHAR(36) PK  -- UUID generated server-side
  classroom_id    VARCHAR(36) FK → classrooms.id
  owner_id        BIGINT FK → users.id
  channel         VARCHAR(255)    -- Reverb channel name
  ws_url          VARCHAR(500)    -- Reverb WS URL sent to clients
  status          ENUM('active','ended') DEFAULT 'active'
  started_at      TIMESTAMP
  ended_at        TIMESTAMP NULL

session_participants
  id              BIGINT PK AUTO_INCREMENT
  session_id      VARCHAR(36) FK → sessions.id
  user_id         BIGINT NULL FK → users.id   -- null = guest/unauthenticated
  student_id      VARCHAR(255)                -- app-side ID (online user ID or name)
  student_name    VARCHAR(255)
  joined_at       TIMESTAMP
  left_at         TIMESTAMP NULL

quiz_submissions
  id              VARCHAR(36) PK  -- UUID
  session_id      VARCHAR(36) FK → sessions.id
  student_id      VARCHAR(255)
  student_name    VARCHAR(255)
  quiz_id         VARCHAR(36)
  quiz_title      VARCHAR(255)
  score           INT DEFAULT 0
  total           INT DEFAULT 0
  answers_json    JSON            -- [{question_id, answer, is_correct}]
  submitted_at    TIMESTAMP

chat_messages
  id              BIGINT PK AUTO_INCREMENT
  session_id      VARCHAR(36) FK → sessions.id
  sender_id       VARCHAR(255)    -- user's online_user_id or name
  sender_name     VARCHAR(255)
  is_teacher      TINYINT(1) DEFAULT 0
  body            TEXT
  sent_at         TIMESTAMP

hand_queue
  id              BIGINT PK AUTO_INCREMENT
  session_id      VARCHAR(36) FK → sessions.id
  student_id      VARCHAR(255)
  student_name    VARCHAR(255)
  raised_at       TIMESTAMP
  answered_at     TIMESTAMP NULL
  UNIQUE KEY uq_hand (session_id, student_id)
```

---

## Phase 1 — Account Linking & API Client

### Goal
Issue Sanctum tokens so Flutter can authenticate against the backend.

### Endpoints

#### POST `/api/auth/register`
**Body:**
```json
{ "name": "Alice", "email": "alice@example.com", "password": "secret", "password_confirmation": "secret" }
```
**Response 201:**
```json
{ "token": "1|abc...", "user": { "id": 5, "name": "Alice", "email": "alice@example.com" } }
```

#### POST `/api/auth/login`
**Body:**
```json
{ "email": "alice@example.com", "password": "secret" }
```
**Response 200:**
```json
{ "token": "2|def...", "user": { "id": 5, "name": "Alice" } }
```
**Response 401:** `{ "message": "Invalid credentials" }`

#### POST `/api/auth/logout` *(requires auth)*
Revokes the current token.
**Response 204:** *(no body)*

#### GET `/api/user` *(requires auth)*
**Response 200:**
```json
{ "id": 5, "name": "Alice", "email": "alice@example.com" }
```

### Laravel Files to Create
```
routes/api.php              — register route group
app/Http/Controllers/Auth/
    AuthController.php      — register(), login(), logout(), me()
```

### Notes
- Use `Auth::guard('sanctum')` middleware on protected routes.
- The Flutter app stores `user.id` as `ONLINE_USER_ID` and `user.name` as `ONLINE_USER_NAME` in secure storage.
- Token has no expiry by default; add `expiration` in `config/sanctum.php` if needed.

---

## Phase 2 — Publish Classrooms & Sync Materials

### Goal
Teacher can push local classrooms and materials to the server. Students can later browse them.

### Endpoints

#### POST `/api/classrooms` *(requires auth)*
Creates a published classroom. The Flutter app sends the local classroom UUID as the ID.
**Body:**
```json
{ "id": "local-uuid-...", "name": "Math 101", "description": "...", "schedule": "MWF 8AM" }
```
**Response 201:**
```json
{ "id": "local-uuid-...", "name": "Math 101", "owner_id": 5 }
```

#### PUT `/api/classrooms/{id}` *(requires auth, must own)*
**Body:** same shape as POST, partial updates OK.
**Response 200:** updated classroom object.

#### DELETE `/api/classrooms/{id}` *(requires auth, must own)*
Also deletes all associated materials and active sessions.
**Response 204**

#### POST `/api/classrooms/{id}/materials` *(requires auth, must own)*
Multipart file upload.
**Form fields:**
| Field | Type | Description |
|---|---|---|
| `id` | string | Material UUID from Flutter |
| `file` | file | Binary file data |
| `original_name` | string | Display name |
| `mime_type` | string | e.g. `application/pdf` |
| `size_bytes` | integer | File size |

**Response 201:**
```json
{
  "id": "material-uuid-...",
  "original_name": "Lesson 1.pdf",
  "file_url": "https://api.yourdomain.com/storage/materials/abc.pdf",
  "mime_type": "application/pdf",
  "size_bytes": 204800
}
```
The `file_url` is stored by Flutter as `remote_url`.

#### DELETE `/api/classrooms/{id}/materials/{mid}` *(requires auth, must own)*
Deletes the file from storage and the DB record.
**Response 204**

### Laravel Files to Create
```
app/Http/Controllers/
    ClassroomController.php   — store(), update(), destroy()
    MaterialController.php    — store(), destroy()
app/Models/
    Classroom.php
    Material.php
app/Policies/
    ClassroomPolicy.php       — ensures only owner can modify
database/migrations/
    create_classrooms_table.php
    create_materials_table.php
```

### Storage
Run `php artisan storage:link` so `/storage/` is publicly accessible.
Store files at `storage/app/public/materials/{classroom_id}/{filename}`.

---

## Phase 3 — Online Classroom Browser (Student)

### Goal
Students can discover published classrooms and check for active sessions.

### Endpoints

#### GET `/api/classrooms`
Public endpoint — no auth required.
**Query params:** `search` (optional), `page` (optional)
**Response 200:**
```json
{
  "data": [
    {
      "id": "uuid-...",
      "name": "Math 101",
      "description": "...",
      "schedule": "MWF 8AM",
      "owner_name": "Mr. Smith",
      "material_count": 5
    }
  ]
}
```

#### GET `/api/classrooms/{id}`
**Response 200:**
```json
{
  "id": "uuid-...",
  "name": "Math 101",
  "description": "...",
  "schedule": "MWF 8AM",
  "owner_name": "Mr. Smith"
}
```
**Response 404** if not found.

#### GET `/api/classrooms/{id}/materials`
**Response 200:**
```json
{
  "data": [
    {
      "id": "mat-uuid-...",
      "original_name": "Lesson 1.pdf",
      "file_url": "https://...",
      "mime_type": "application/pdf",
      "size_bytes": 204800
    }
  ]
}
```

#### GET `/api/classrooms/{id}/active-session`
**Response 200** (session exists):
```json
{
  "id": "session-uuid-...",
  "channel": "session.session-uuid-...",
  "ws_url": "ws://your-reverb-host:8080",
  "started_at": "2026-07-10T08:00:00Z"
}
```
**Response 404** if no active session.

#### POST `/api/classrooms/{id}/join` *(requires auth)*
Records student interest / triggers PARTICIPANT_UPDATE event.
**Body:** `{ "student_id": "...", "student_name": "Alice" }`
**Response 200:** `{ "status": "joined" }`

### Laravel Files to Create
```
app/Http/Controllers/
    PublicClassroomController.php   — index(), show(), materials(), activeSession(), join()
```

---

## Phase 4 — Online Live Session (WebSocket)

### Goal
Teacher creates a live session; students connect via Reverb (Pusher protocol).

### Endpoints

#### POST `/api/sessions` *(requires auth)*
**Body:** `{ "classroom_id": "uuid-..." }`
**Response 201:**
```json
{
  "id": "session-uuid-...",
  "classroom_id": "uuid-...",
  "channel": "session.session-uuid-...",
  "ws_url": "ws://your-reverb-host:8080",
  "status": "active",
  "started_at": "2026-07-10T08:00:00Z"
}
```
- Generate a UUID for the session server-side.
- Channel name convention: `session.{session_id}`.
- `ws_url` is the raw Reverb WebSocket URL (the Flutter app derives `wss://` / `ws://` from it).
- Only one active session per classroom at a time — return 409 if one already exists.

#### GET `/api/sessions/{id}` *(requires auth)*
**Response 200:** same shape as POST response.

#### POST `/api/sessions/{id}/end` *(requires auth, must own)*
Sets `status = 'ended'`, `ended_at = now()`.
Broadcasts `PRESENTATION_ENDED` to the channel.
**Response 204**

#### GET `/api/sessions/{id}/participants` *(requires auth)*
**Response 200:**
```json
{
  "data": [
    { "student_id": "42", "student_name": "Alice", "joined_at": "..." }
  ]
}
```

#### POST `/api/sessions/{id}/broadcast` *(requires auth, must own)*
Generic event broadcaster — teacher pushes any event to all channel subscribers.
**Body:**
```json
{ "event": "SLIDE_START", "data": { "url": "https://...", "filename": "Lesson 1.pdf", "mime_type": "application/pdf" } }
```
**Response 204**
Internally calls: `broadcast(new SessionEvent($session->channel, $event, $data))`.

### Reverb Channel Setup
Use a **public channel** (no Pusher auth needed from the Flutter app's Pusher-protocol client):
- Channel name: `session.{session_id}`
- Event name: pass through as-is (e.g. `SLIDE_START`, `QUIZ_START`)

The Flutter app sends Pusher subscribe frames:
```json
{ "event": "pusher:subscribe", "data": { "channel": "session.abc123" } }
```
Reverb handles this natively; no server-side auth callback needed for public channels.

### Events Broadcast via This Endpoint

| Event | Data shape | Direction |
|---|---|---|
| `HANDSHAKE_ACK` | `{ status, current_file?, current_quiz? }` | Server → Student |
| `SLIDE_START` | `{ url, filename, mime_type }` | Teacher → All |
| `SLIDE_CHANGE` | `{ page_index }` | Teacher → All |
| `PRESENTATION_ENDED` | `{}` | Teacher → All |
| `VIDEO_SESSION_READY` | `{ sessionId }` | Teacher → All |
| `VIDEO_SESSION_ENDED` | `{ sessionId }` | Teacher → All |
| `PARTICIPANT_UPDATE` | `{ source, name, connected, total_lan? }` | Bridge → All |

### Laravel Files to Create
```
app/Http/Controllers/
    SessionController.php       — store(), show(), end(), participants(), broadcast()
app/Models/
    Session.php
    SessionParticipant.php
app/Events/
    SessionEvent.php            — implements ShouldBroadcast
config/broadcasting.php         — set BROADCAST_CONNECTION=reverb
.env                            — REVERB_APP_ID, REVERB_APP_KEY, REVERB_APP_SECRET, REVERB_HOST, REVERB_PORT
database/migrations/
    create_sessions_table.php
    create_session_participants_table.php
```

### `SessionEvent.php` skeleton
```php
class SessionEvent implements ShouldBroadcast
{
    use Dispatchable, InteractsWithSockets, SerializesModels;

    public function __construct(
        public string $channel,
        public string $eventName,
        public array  $data = [],
    ) {}

    public function broadcastOn(): Channel
    {
        return new Channel($this->channel);
    }

    public function broadcastAs(): string
    {
        return $this->eventName;
    }

    public function broadcastWith(): array
    {
        return array_merge($this->data, ['event' => $this->eventName]);
    }
}
```

### `.env` additions
```env
BROADCAST_CONNECTION=reverb

REVERB_APP_ID=asuratech
REVERB_APP_KEY=asuratech-key
REVERB_APP_SECRET=asuratech-secret
REVERB_HOST=0.0.0.0
REVERB_PORT=8080
REVERB_SCHEME=ws
```
Run: `php artisan reverb:start --host=0.0.0.0 --port=8080`

---

## Phase 5 — WebRTC Signaling Channel

### Goal
The Reverb channel is used as the signaling transport for WebRTC peer connections. No new HTTP endpoints are needed — signaling events travel through the existing `/api/sessions/{id}/broadcast` endpoint.

### Signaling Events (all via `POST /api/sessions/{id}/broadcast`)

| Event | Payload | Direction |
|---|---|---|
| `WEBRTC_JOIN` | `{ from, name, sessionId }` | Student → All |
| `WEBRTC_OFFER` | `{ from, to, sdp, type }` | Teacher → Student |
| `WEBRTC_ANSWER` | `{ from, to, sdp, type }` | Student → Teacher |
| `WEBRTC_ICE` | `{ from, to, candidate }` | Both |
| `MUTE_COMMAND` | `{ target: id\|'all', action: 'mute'\|'unmute' }` | Teacher → Students |
| `CALLED_ON` | `{ target: student_id }` | Teacher → Student |

### Server Responsibilities
- Forward all of the above events to the channel without modification (the broadcast endpoint already does this).
- No server-side processing of SDP or ICE candidates — the server is a dumb relay.

### STUN/TURN (optional but recommended for production)
The Flutter app uses Google STUN by default. For users behind symmetric NAT, add a TURN server:
```env
TURN_HOST=turn.yourdomain.com
TURN_PORT=3478
TURN_USERNAME=asuratech
TURN_CREDENTIAL=your-turn-secret
```
Expose these via `GET /api/rtc/config` if you want the app to fetch TURN credentials dynamically.

---

## Phase 6 — Online Quiz & Chat

### Goal
Students can take quizzes broadcast by the teacher and exchange chat messages during a live session.

### Endpoints

#### POST `/api/sessions/{id}/quiz/submit` *(requires auth)*
Student submits quiz answers.
**Body:**
```json
{
  "student_id":   "42",
  "student_name": "Alice",
  "quiz_id":      "quiz-uuid-...",
  "quiz_title":   "Chapter 3 Quiz",
  "answers": [
    { "question_id": "q1", "answer": "B" },
    { "question_id": "q2", "answer": "True" }
  ]
}
```
Server should:
1. Store the raw submission in `quiz_submissions`.
2. Return a score if the server holds the answer key — or return 200 with `{ "status": "received" }` and let the Flutter app score locally if the app already has the questions with answers.

**Response 200:**
```json
{ "status": "received", "score": 2, "total": 2 }
```

#### GET `/api/sessions/{id}/quiz/results` *(requires auth, must own)*
Returns all submissions for the current/last quiz.
**Response 200:**
```json
{
  "data": [
    {
      "student_name": "Alice",
      "quiz_title": "Chapter 3 Quiz",
      "score": 2,
      "total": 2,
      "submitted_at": "2026-07-10T09:15:00Z"
    }
  ]
}
```

#### GET `/api/sessions/{id}/chat`
Fetch chat history (last 100 messages).
**Response 200:**
```json
{
  "data": [
    {
      "sender_id":   "42",
      "sender_name": "Alice",
      "is_teacher":  false,
      "body":        "Hello class!",
      "sent_at":     "2026-07-10T09:00:00Z"
    }
  ]
}
```

#### POST `/api/sessions/{id}/chat` *(requires auth)*
Send a chat message.
**Body:**
```json
{ "sender_id": "42", "sender_name": "Alice", "is_teacher": false, "body": "Hello!" }
```
**Response 201:** the created message object.

After storing, broadcast `CHAT_MESSAGE` to the session channel:
```json
{
  "event":       "CHAT_MESSAGE",
  "sender_id":   "42",
  "sender_name": "Alice",
  "is_teacher":  false,
  "body":        "Hello!",
  "sent_at":     "2026-07-10T09:00:00Z"
}
```

### Laravel Files to Create
```
app/Http/Controllers/
    QuizSubmissionController.php   — store(), results()
    ChatController.php             — index(), store()
database/migrations/
    create_quiz_submissions_table.php
    create_chat_messages_table.php
```

---

## Phase 7 — Raise Hand & Participant Control

### Goal
Students signal they want to speak; teacher picks one to unmute via WebRTC `CALLED_ON`.

### Endpoints

#### POST `/api/sessions/{id}/hand/raise` *(requires auth)*
**Body:** `{ "student_id": "42", "student_name": "Alice" }`

Server should:
1. Upsert a row in `hand_queue` for this student.
2. Broadcast `HAND_UPDATE` to the channel.

**Response 204**

#### POST `/api/sessions/{id}/hand/lower` *(requires auth)*
**Body:** `{ "student_id": "42" }`

Server should:
1. Delete the student's row from `hand_queue`.
2. Broadcast `HAND_UPDATE` to the channel.

**Response 204**

#### POST `/api/sessions/{id}/hand/call` *(requires auth, must own)*
Teacher picks a student.
**Body:** `{ "student_id": "42" }`

Server should:
1. Mark `answered_at = now()` in `hand_queue` (or delete the row).
2. Broadcast `CALLED_ON { target: "42" }` to the channel.
3. Broadcast updated `HAND_UPDATE` to the channel.

**Response 204**

### HAND_UPDATE event shape
```json
{
  "event": "HAND_UPDATE",
  "queue": [
    { "id": "42", "name": "Alice" },
    { "id": "99", "name": "Bob" }
  ]
}
```
Ordered by `raised_at ASC` (first raised = first in queue).

### Laravel Files to Create
```
app/Http/Controllers/
    HandController.php   — raise(), lower(), call()
database/migrations/
    create_hand_queue_table.php
```

---

## Phase 8 — Hybrid Session Bridge

### Goal
No new endpoints needed. The Flutter app handles hybrid logic client-side.

### Server Responsibilities
- The `/api/sessions/{id}/broadcast` endpoint must handle high-frequency calls (it is called for every LAN student join/leave event when the bridge is active).
- Consider rate-limiting `PARTICIPANT_UPDATE` broadcasts (e.g. max 1 per second per session) to avoid flooding Reverb with LAN attendance noise.
- Ensure Reverb channel message rate limits are sufficient (`config/reverb.php` → `max_message_size`).

### Rate-Limiting Suggestion
In `RouteServiceProvider`:
```php
RateLimiter::for('broadcast', function (Request $request) {
    return Limit::perSecond(10)->by($request->route('id'));
});
```
Apply to the broadcast route: `->middleware(['auth:sanctum', 'throttle:broadcast'])`.

---

## Reverb Setup Summary

### Install
```bash
composer require laravel/reverb
php artisan reverb:install
```

### Start (dev)
```bash
php artisan reverb:start --host=0.0.0.0 --port=8080 --debug
```

### Production (Supervisor)
```ini
[program:reverb]
command=php /var/www/html/artisan reverb:start --host=0.0.0.0 --port=8080
autostart=true
autorestart=true
stderr_logfile=/var/log/reverb.err.log
stdout_logfile=/var/log/reverb.out.log
```

### Flutter WS URL format
The Flutter app constructs the WebSocket URL from `ws_url` returned by `POST /api/sessions`.
Return the raw host:port URL — Flutter derives `wss://` for HTTPS origins automatically.
```
ws://192.168.1.10:8080/app/asuratech-key?protocol=7&client=js&version=7.4.0&flash=false
```

---

## Sanctum Setup Checklist

```bash
composer require laravel/sanctum
php artisan vendor:publish --provider="Laravel\Sanctum\SanctumServiceProvider"
php artisan migrate
```

In `app/Http/Kernel.php` (or `bootstrap/app.php` in Laravel 11):
```php
'api' => [
    \Laravel\Sanctum\Http\Middleware\EnsureFrontendRequestsAreStateful::class,
    'throttle:api',
    \Illuminate\Routing\Middleware\SubstituteBindings::class,
],
```

---

## CORS Setup

The Flutter Android app makes HTTP requests directly to the server IP.
In `config/cors.php`:
```php
'allowed_origins' => ['*'],       // lock down in production
'allowed_methods' => ['*'],
'allowed_headers' => ['*'],
'supports_credentials' => false,
```

---

## Suggested Route File Structure

```php
// routes/api.php

// Public auth
Route::post('/auth/register', [AuthController::class, 'register']);
Route::post('/auth/login',    [AuthController::class, 'login']);

// Public classroom browser
Route::get('/classrooms',                     [PublicClassroomController::class, 'index']);
Route::get('/classrooms/{id}',                [PublicClassroomController::class, 'show']);
Route::get('/classrooms/{id}/materials',      [PublicClassroomController::class, 'materials']);
Route::get('/classrooms/{id}/active-session', [PublicClassroomController::class, 'activeSession']);

// Authenticated
Route::middleware('auth:sanctum')->group(function () {

    Route::post('/auth/logout', [AuthController::class, 'logout']);
    Route::get('/user',         [AuthController::class, 'me']);

    // Classrooms (teacher)
    Route::post  ('/classrooms',                          [ClassroomController::class, 'store']);
    Route::put   ('/classrooms/{id}',                     [ClassroomController::class, 'update']);
    Route::delete('/classrooms/{id}',                     [ClassroomController::class, 'destroy']);
    Route::post  ('/classrooms/{id}/materials',           [MaterialController::class, 'store']);
    Route::delete('/classrooms/{id}/materials/{mid}',     [MaterialController::class, 'destroy']);
    Route::post  ('/classrooms/{id}/join',                [PublicClassroomController::class, 'join']);

    // Sessions
    Route::post  ('/sessions',                            [SessionController::class, 'store']);
    Route::get   ('/sessions/{id}',                       [SessionController::class, 'show']);
    Route::post  ('/sessions/{id}/end',                   [SessionController::class, 'end']);
    Route::get   ('/sessions/{id}/participants',          [SessionController::class, 'participants']);
    Route::post  ('/sessions/{id}/broadcast',             [SessionController::class, 'broadcast']);

    // Quiz & Chat
    Route::post('/sessions/{id}/quiz/submit',             [QuizSubmissionController::class, 'store']);
    Route::get ('/sessions/{id}/quiz/results',            [QuizSubmissionController::class, 'results']);
    Route::get ('/sessions/{id}/chat',                    [ChatController::class, 'index']);
    Route::post('/sessions/{id}/chat',                    [ChatController::class, 'store']);

    // Raise hand
    Route::post('/sessions/{id}/hand/raise',              [HandController::class, 'raise']);
    Route::post('/sessions/{id}/hand/lower',              [HandController::class, 'lower']);
    Route::post('/sessions/{id}/hand/call',               [HandController::class, 'call']);
});
```

---

## Testing Checklist (per phase)

### Phase 1
- [ ] Register returns token + user id
- [ ] Login with wrong password returns 401
- [ ] Protected route rejects request without token
- [ ] Logout invalidates token

### Phase 2
- [ ] POST classroom stores record, returns UUID
- [ ] Upload material stores file, returns public URL
- [ ] DELETE classroom cascades materials + file deletion
- [ ] Owner-only policy: other user gets 403

### Phase 3
- [ ] Unauthenticated GET /classrooms returns list
- [ ] active-session returns 404 when no session
- [ ] active-session returns session object when active

### Phase 4
- [ ] POST /sessions returns channel + ws_url
- [ ] Second POST for same classroom returns 409
- [ ] POST /sessions/{id}/broadcast fires Reverb event (check Reverb debug logs)
- [ ] POST /sessions/{id}/end sets status=ended and broadcasts PRESENTATION_ENDED

### Phase 5
- [ ] WEBRTC_OFFER event reaches channel after POST /broadcast
- [ ] MUTE_COMMAND reaches channel

### Phase 6
- [ ] POST /chat broadcasts CHAT_MESSAGE to channel
- [ ] GET /chat returns history in chronological order
- [ ] Quiz submit stores record and returns score

### Phase 7
- [ ] POST /hand/raise broadcasts HAND_UPDATE with queue
- [ ] POST /hand/call broadcasts CALLED_ON with correct target + updated HAND_UPDATE
- [ ] Duplicate raise replaces existing entry (upsert)

### Phase 8
- [ ] Broadcast endpoint handles 10 rapid calls per second without error
- [ ] Reverb does not disconnect clients under sustained PARTICIPANT_UPDATE load

---

## Notes
- All IDs sent by the Flutter app are UUIDs generated on-device. Accept them as-is rather than auto-incrementing.
- The Flutter app sends `classroom_id` (the local UUID) when creating sessions — this is the same UUID used as `classrooms.id` in your DB.
- `ws_url` in the sessions response must point to your Reverb server, NOT the Laravel HTTP server. They run on different ports.
- For the Pusher protocol handshake, Reverb expects the URL pattern: `ws://{host}:{port}/app/{app_key}`.
- Online quiz scoring: the Flutter app scores locally using the questions it received. The server only needs to store the submission — no server-side scoring is required unless you want a results dashboard.
