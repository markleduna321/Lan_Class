# Flutter Handoff: WebRTC to Jitsi / JaaS Migration

## Summary
The backend has been updated so the Flutter app can migrate away from custom WebRTC signaling and use Jitsi / JaaS instead, while keeping the existing classroom/session API structure as stable as possible.

This means:
- Video calling should now use Jitsi room data from the API.
- Existing classroom, materials, quiz, chat, and hand-raise APIs remain available.
- Legacy signaling fields are still present temporarily for compatibility, but Flutter should stop depending on them.

## Recommended Flutter Join Flow
1. Authenticate with `POST /api/auth/login` or `POST /api/auth/register`.
2. Store the returned bearer token.
3. Fetch classrooms with `GET /api/classrooms`.
4. Get the active session using `GET /api/classrooms/{id}/active-session`.
5. Request final Jitsi join data using `POST /api/sessions/{id}/join`.
6. Join Jitsi in Flutter using:
   - `room_name`
   - `display_name`
   - optional `jwt`
   - optional JaaS `app_id`

## Authentication
All protected endpoints accept bearer token auth.

Header:

```http
Authorization: Bearer {token}
Accept: application/json
```

## Auth APIs

### POST /api/auth/login
Request:

```json
{
  "email": "user@example.com",
  "password": "secret"
}
```

Response:

```json
{
  "user": {
    "id": 1,
    "name": "Test User",
    "email": "user@example.com",
    "email_verified_at": null,
    "created_at": "2026-07-10T10:00:00.000000Z",
    "updated_at": "2026-07-10T10:00:00.000000Z"
  },
  "token": "1|sanctum-token-here"
}
```

### POST /api/auth/register
Request:

```json
{
  "name": "Test User",
  "email": "user@example.com",
  "password": "secret123",
  "password_confirmation": "secret123"
}
```

Response:

```json
{
  "user": {
    "id": 1,
    "name": "Test User",
    "email": "user@example.com",
    "email_verified_at": null,
    "created_at": "2026-07-10T10:00:00.000000Z",
    "updated_at": "2026-07-10T10:00:00.000000Z"
  },
  "token": "1|sanctum-token-here"
}
```

### POST /api/auth/logout
Response: `204 No Content`

### GET /api/user
Response:

```json
{
  "id": 1,
  "name": "Test User",
  "email": "user@example.com",
  "email_verified_at": null,
  "created_at": "2026-07-10T10:00:00.000000Z",
  "updated_at": "2026-07-10T10:00:00.000000Z"
}
```

## Classroom APIs

### POST /api/classrooms
Protected.

Request:

```json
{
  "id": "uuid-or-client-id",
  "name": "Classroom 101",
  "description": "Basic math class",
  "schedule": "Mon-Fri 1pm to 3pm"
}
```

### PUT /api/classrooms/{id}
Protected.

Request:

```json
{
  "name": "Updated classroom name",
  "description": "Updated description",
  "schedule": "Updated schedule"
}
```

### DELETE /api/classrooms/{id}
Protected.

### POST /api/classrooms/{id}/materials
Protected. Multipart upload.

Expected multipart field:
- `file`

### DELETE /api/classrooms/{id}/materials/{mid}
Protected.

### GET /api/classrooms
Public.

Optional query:
- `search`

### GET /api/classrooms/{id}
Public.

### GET /api/classrooms/{id}/materials
Public.

### GET /api/classrooms/{id}/active-session
Public.
Returns `404` if there is no active session.

### POST /api/classrooms/{id}/join
Protected.
This marks the authenticated user as a participant for the current active session.

Response:

```json
{
  "message": "Joined classroom successfully.",
  "session": {
    "id": "354f3b58-7a3f-419d-8263-c37f00e528cb",
    "classroom_id": "classroom-id",
    "owner_id": 1,
    "channel": "session.354f3b58-7a3f-419d-8263-c37f00e528cb",
    "presence_channel": "session.354f3b58-7a3f-419d-8263-c37f00e528cb",
    "ws_url": "legacy-only",
    "join_endpoint": "/api/sessions/354f3b58-7a3f-419d-8263-c37f00e528cb/join",
    "video_provider": "jitsi",
    "room_name": "session-354f3b58-7a3f-419d-8263-c37f00e528cb",
    "room_url": "https://meet.jit.si/session-354f3b58-7a3f-419d-8263-c37f00e528cb",
    "jitsi": {
      "provider": "jitsi",
      "room_name": "session-354f3b58-7a3f-419d-8263-c37f00e528cb",
      "room_url": "https://meet.jit.si/session-354f3b58-7a3f-419d-8263-c37f00e528cb",
      "base_url": "https://meet.jit.si",
      "jaas_app_id": null,
      "require_jwt": false
    },
    "status": "active",
    "started_at": "2026-07-10T12:00:00.000000Z",
    "ended_at": null,
    "participant_count": 1,
    "hand_queue": []
  }
}
```

## Session APIs

### POST /api/sessions
Protected.
Teacher starts a live session.

Request:

```json
{
  "classroom_id": "classroom-id"
}
```

Response:

```json
{
  "id": "354f3b58-7a3f-419d-8263-c37f00e528cb",
  "classroom_id": "classroom-id",
  "owner_id": 1,
  "channel": "session.354f3b58-7a3f-419d-8263-c37f00e528cb",
  "presence_channel": "session.354f3b58-7a3f-419d-8263-c37f00e528cb",
  "ws_url": "legacy-only",
  "join_endpoint": "/api/sessions/354f3b58-7a3f-419d-8263-c37f00e528cb/join",
  "video_provider": "jitsi",
  "room_name": "session-354f3b58-7a3f-419d-8263-c37f00e528cb",
  "room_url": "https://meet.jit.si/session-354f3b58-7a3f-419d-8263-c37f00e528cb",
  "jitsi": {
    "provider": "jitsi",
    "room_name": "session-354f3b58-7a3f-419d-8263-c37f00e528cb",
    "room_url": "https://meet.jit.si/session-354f3b58-7a3f-419d-8263-c37f00e528cb",
    "base_url": "https://meet.jit.si",
    "jaas_app_id": null,
    "require_jwt": false
  },
  "status": "active",
  "started_at": "2026-07-10T12:00:00.000000Z",
  "ended_at": null,
  "participant_count": 0,
  "hand_queue": []
}
```

### GET /api/sessions/{id}
Protected.
Used to inspect session details and current hand queue.

### POST /api/sessions/{id}/join
Protected.
This is the new Flutter-primary Jitsi join endpoint.

Response:

```json
{
  "session_id": "354f3b58-7a3f-419d-8263-c37f00e528cb",
  "provider": "jitsi",
  "room_name": "session-354f3b58-7a3f-419d-8263-c37f00e528cb",
  "room_url": "https://meet.jit.si/session-354f3b58-7a3f-419d-8263-c37f00e528cb",
  "role": "participant",
  "display_name": "Test User",
  "subject": "Classroom 101",
  "jaas": {
    "app_id": null,
    "require_jwt": false
  },
  "jwt": null,
  "legacy": {
    "channel": "session.354f3b58-7a3f-419d-8263-c37f00e528cb",
    "ws_url": "legacy-only"
  }
}
```

Flutter should use:
- `room_name`
- `display_name`
- `jwt` if not null
- `room_url` only if you need a raw browser/open-external fallback

Role meaning:
- `moderator`: teacher / session owner
- `participant`: learner

### POST /api/sessions/{id}/end
Protected.
Teacher ends the session.

### GET /api/sessions/{id}/participants
Protected.
Returns participant list.

### POST /api/sessions/{id}/broadcast
Protected.
Transitional only.
Keep this only for app-level events if needed.
Do not use this for Jitsi media negotiation.

Legacy events that Flutter should stop using:
- `WEBRTC_JOIN`
- `WEBRTC_OFFER`
- `WEBRTC_ANSWER`
- `WEBRTC_ICE`

## Quiz APIs

### POST /api/sessions/{id}/quiz/submit
Protected.

Request example:

```json
{
  "student_id": "1",
  "student_name": "Test User",
  "quiz_id": "quiz-1",
  "quiz_title": "Quiz title",
  "answers": [
    {
      "question_id": "quiz-1-q1",
      "answer": "My answer"
    }
  ]
}
```

### GET /api/sessions/{id}/quiz/results
Protected.
Teacher-facing results.

## Chat APIs

### GET /api/sessions/{id}/chat
Protected.

### POST /api/sessions/{id}/chat
Protected.

Request example:

```json
{
  "sender_id": "1",
  "sender_name": "Test User",
  "is_teacher": false,
  "body": "Hello class"
}
```

## Hand Raise APIs

### POST /api/sessions/{id}/hand/raise
Protected.

Request:

```json
{
  "student_id": "1",
  "student_name": "Test User"
}
```

### POST /api/sessions/{id}/hand/lower
Protected.

Request:

```json
{
  "student_id": "1",
  "student_name": "Test User"
}
```

### POST /api/sessions/{id}/hand/call
Protected.
Teacher action.

Request:

```json
{
  "student_id": "1",
  "student_name": "Test User"
}
```

## WebRTC to Jitsi Migration Mapping

| Old WebRTC Concept | New Jitsi Equivalent |
|---|---|
| `ws_url` | `room_url` |
| `channel` for media session | `room_name` |
| `WEBRTC_JOIN` | `POST /api/sessions/{id}/join` |
| `WEBRTC_OFFER` | Not needed |
| `WEBRTC_ANSWER` | Not needed |
| `WEBRTC_ICE` | Not needed |
| custom peer negotiation | Jitsi SDK handles it |
| Reverb media signaling | Jitsi / JaaS signaling |

## Flutter Implementation Notes

### Join Parameters to Use in Flutter
Use the response from `POST /api/sessions/{id}/join` to configure the Jitsi SDK.

Minimum mapping:
- room name = `room_name`
- display name = `display_name`
- token = `jwt` if present
- subject = `subject`
- audio/video defaults = client-side decision

### Suggested Client Migration Plan
1. Keep current auth flow but switch to bearer token usage consistently.
2. Replace any `WEBRTC_JOIN` call with `POST /api/sessions/{id}/join`.
3. Remove offer/answer/ICE logic from Flutter.
4. Join Jitsi room using the returned room payload.
5. Keep using existing quiz/chat/hand/classroom APIs unchanged.
6. Remove dependency on websocket fields after rollout is complete.

## Environment Values Backend Uses
- `JITSI_BASE_URL`
- `JITSI_APP_ID`
- `JITSI_APP_SECRET`
- `JITSI_REQUIRE_JWT`
- `JITSI_TOKEN_TTL`
- `JITSI_JWT_AUDIENCE`
- `JITSI_JWT_ISSUER`
- `JITSI_JWT_SUBJECT`
- `JITSI_JWT_KEY_ID`

## Files Relevant to This Migration
- [routes/api.php](c:\new_Projects\Updated-ReactTemplate\routes\api.php)
- [app/Http/Controllers/SessionController.php](c:\new_Projects\Updated-ReactTemplate\app\Http\Controllers\SessionController.php)
- [app/Http/Resources/SessionResource.php](c:\new_Projects\Updated-ReactTemplate\app\Http\Resources\SessionResource.php)
- [docs/jitsi-flutter-migration-map.md](c:\new_Projects\Updated-ReactTemplate\docs\jitsi-flutter-migration-map.md)
