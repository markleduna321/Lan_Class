# AsuraTECH LAN Classroom — Android Online Integration Phases

## How to Use This File
- Update the **Status** column when a phase is complete.
- Do not start the next phase until the Laravel API endpoints for that phase are confirmed live.
- Each phase is independently deployable and testable.

---

## Phase Status

| Phase | Title | Status |
|---|---|---|
| 1 | Account Linking & API Client | ✅ Done |
| 2 | Publish Classrooms & Sync Materials | ✅ Done |
| 3 | Online Classroom Browser (Student) | ✅ Done |
| 4 | Online Live Session (WebSocket) | ✅ Done |
| 5 | WebRTC Video & Audio | ✅ Done |
| 6 | Online Quiz & Chat | ✅ Done |
| 7 | Raise Hand & Participant Control | ✅ Done |
| 8 | Hybrid Mode (LAN + Online Simultaneously) | ✅ Done |

---

## Phase 1 — Account Linking & API Client
**Goal:** Connect existing local accounts to the Laravel backend. User can log in online alongside their local account.

### Laravel API Endpoints Required
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/auth/login` | Login, returns `{ token, user }` |
| POST | `/api/auth/register` | Register, returns `{ token, user }` |
| POST | `/api/auth/logout` | Revoke Sanctum token (Bearer auth) |
| GET  | `/api/user` | Get authenticated user profile |

### Secure Storage Keys Added
| Key | Value |
|---|---|
| `ONLINE_BASE_URL` | Laravel server base URL (e.g. `https://api.yourdomain.com`) |
| `ONLINE_TOKEN` | Sanctum Bearer token |
| `ONLINE_USER_ID` | Laravel user ID (integer as string) |
| `ONLINE_USER_NAME` | Full name from Laravel |

### DB Change
- Version 10 → 11
- `ALTER TABLE users ADD COLUMN remote_id TEXT` — stores the Laravel user ID once linked

### Files Created
- `lib/services/cloud_api_service.dart` — base HTTP client with token management

### Files Modified
- `lib/database/asura_db.dart` — v11, users migration
- `lib/database/asura_repository.dart` — `updateUserRemoteId()`
- `lib/features/auth/login_view.dart` — "Also sign in online" toggle
- `lib/features/auth/signup_view.dart` — "Register online too" toggle
- `lib/features/classroom/user_profile_view.dart` — Cloud Account section (server URL, link/unlink)

---

## Phase 2 — Publish Classrooms & Sync Materials
**Goal:** Teacher can push local classrooms and materials to the Laravel backend.

### Laravel API Endpoints Required
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/classrooms` | Create classroom online |
| PUT | `/api/classrooms/{id}` | Update classroom |
| DELETE | `/api/classrooms/{id}` | Unpublish / delete classroom |
| POST | `/api/classrooms/{id}/materials` | Upload material file (multipart) |
| DELETE | `/api/classrooms/{id}/materials/{mid}` | Remove material from cloud |

### DB Change
- Version 11 → 12
- `ALTER TABLE classrooms ADD COLUMN remote_id TEXT`
- `ALTER TABLE classrooms ADD COLUMN is_published INTEGER DEFAULT 0`
- `ALTER TABLE materials ADD COLUMN remote_id TEXT`
- `ALTER TABLE materials ADD COLUMN remote_url TEXT`

### Files Created
- `lib/services/cloud_sync_service.dart` — `publishClassroom()`, `syncMaterial()`, `unpublishClassroom()`

### Files Modified
- `lib/database/asura_db.dart` — v12, classrooms + materials migration
- `lib/database/asura_repository.dart` — update/publish helpers
- `lib/features/classroom/classroom_hub_view.dart` — cloud icon badge, publish/unpublish menu
- `lib/features/classroom/materials_library_view.dart` — upload to cloud button + progress

---

## Phase 3 — Online Classroom Browser (Student)
**Goal:** Students can discover published classrooms and download materials without being on the teacher's LAN.

### Room Mode Logic
- A saved classroom checks both LAN beacon (UDP) and Laravel API for active session
- If online session active → "Join Online" button shown
- If LAN beacon detected → "Join via LAN" button shown
- If neither → "Room is offline — materials available"
- Both modes share the same classroom entry in the student's saved list

### Laravel API Endpoints Required
| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/classrooms` | List all published classrooms |
| GET | `/api/classrooms/{id}` | Classroom detail |
| GET | `/api/classrooms/{id}/materials` | Material list with download URLs |
| GET | `/api/classrooms/{id}/active-session` | Returns active session or 404 |
| POST | `/api/classrooms/{id}/join` | Student join request |

### Files Created
- `lib/features/online/online_classroom_browser_view.dart`
- `lib/features/online/online_classroom_detail_view.dart`

### Files Modified
- `lib/features/classroom/student_join_view.dart` — "Browse Online" tab added alongside LAN scan

---

## Phase 4 — Online Live Session (WebSocket) ✅ Done
**Goal:** Flutter app connects to Laravel Reverb for a live online session. Events mirror the LAN WebSocket protocol.

### WS Events (matches LAN events)
| Event | Direction | Description |
|---|---|---|
| `HANDSHAKE` | Client → Server | Student joins session |
| `HANDSHAKE_ACK` | Server → Client | Confirm join, send current state |
| `SLIDE_START` | Server → Client | Presentation started |
| `SLIDE_CHANGE` | Server → Client | Page changed |
| `PRESENTATION_ENDED` | Server → Client | Presentation stopped |
| `QUIZ_START` | Server → Client | Quiz launched |
| `QUIZ_ENDED` | Server → Client | Quiz closed |
| `PARTICIPANT_UPDATE` | Server → Client | Someone joined/left/muted |

### Laravel API Endpoints Required
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/sessions` | Teacher creates live session |
| GET | `/api/sessions/{id}` | Session state |
| POST | `/api/sessions/{id}/end` | Teacher ends session |
| GET | `/api/sessions/{id}/participants` | Participant list |

### Files Created
- `lib/services/online_session_service.dart`
- `lib/features/online/online_session_lobby_view.dart`

### Files Modified
- `lib/features/classroom/teacher_dashboard_view.dart` — "Start Online Session" button
- `lib/features/classroom/student_lobby_view.dart` — detects online session, shows join button

---

## Phase 5 — WebRTC Video & Audio ✅ Done
**Goal:** Video conference works in the Flutter app using `flutter_webrtc` + Laravel signaling channel.

### New Packages
```yaml
flutter_webrtc: ^0.x
permission_handler: ^11.x
```

### WS Signaling Events
| Event | Description |
|---|---|
| `WEBRTC_OFFER` | Caller sends SDP offer |
| `WEBRTC_ANSWER` | Callee responds with SDP answer |
| `WEBRTC_ICE` | ICE candidate exchange |
| `MUTE_COMMAND` | Teacher mutes/unmutes a participant |

### Files Created
- `lib/services/webrtc_service.dart`
- `lib/features/online/online_session_view.dart`
- `lib/features/online/participant_tile_widget.dart`

---

## Phase 6 — Online Quiz & Chat ✅ Done
**Goal:** Quiz and chat work over the internet in a live online session.

### Laravel API Endpoints Required
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/sessions/{id}/quiz/submit` | Student submits answers |
| GET | `/api/sessions/{id}/quiz/results` | Live results for teacher |
| GET | `/api/sessions/{id}/chat` | Chat history |
| POST | `/api/sessions/{id}/chat` | Send message |

### Files Created
- `lib/features/online/online_quiz_player_view.dart`
- `lib/features/online/session_chat_panel.dart`

### Files Modified
- `lib/features/online/online_session_view.dart` — quiz launch + chat panel integration
- `lib/features/online/online_session_lobby_view.dart` — use `OnlineQuizPlayerView`, chat FAB
- `lib/features/classroom/teacher_dashboard_view.dart` — pass `classroomId` to `OnlineSessionView`

---

## Phase 7 — Raise Hand & Participant Control ✅ Done
**Goal:** Students raise hand; teacher picks them to speak (unmute).

### WS Events
| Event | Direction | Description |
|---|---|---|
| `RAISE_HAND` | Client → Server | Student raises hand |
| `LOWER_HAND` | Client → Server | Student lowers hand |
| `HAND_UPDATE` | Server → Client | Broadcast updated hand queue |
| `CALLED_ON` | Server → Client | Sent to specific student when teacher picks them |

### Laravel API Endpoints Required
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/sessions/{id}/hand/raise` | Student raises hand |
| POST | `/api/sessions/{id}/hand/lower` | Student lowers hand |
| POST | `/api/sessions/{id}/hand/call` | Teacher calls on a student |

### Files Modified
- `lib/features/online/online_session_view.dart` — raise hand button (student), hands panel + Call On (teacher), called-on banner
- `lib/features/online/online_session_lobby_view.dart` — raise hand FAB, CALLED_ON notification banner
- `lib/services/webrtc_service.dart` — `calledOn` event type; auto-unmute on CALLED_ON
- `lib/services/online_session_service.dart` — `raiseHand()`, `lowerHand()`, `callOnStudent()` REST helpers

---

## Phase 8 — Hybrid Mode (LAN + Online Simultaneously) ✅ Done
**Goal:** One session serves local LAN students and online students at the same time.

### Logic
- Teacher dashboard gets a **"Start Hybrid Session"** button (teal, shown when nothing is running and classroom is published)
- Starting hybrid: launches both `LanServerIsolateManager` (UDP + local WS) AND `OnlineSessionService` (Laravel WS) simultaneously
- Quiz launch/end events forwarded to both transports automatically
- Slide changes already forwarded to both (existing behaviour from Phase 2/4)
- LAN student join/leave forwarded to Reverb as `PARTICIPANT_UPDATE {source:'lan'}`
- Teacher's video call shows a teal "LAN N" badge in the students header
- **"Stop Hybrid Session"** tears down both in one action with confirmation dialog

### Files Modified
- `lib/features/classroom/teacher_dashboard_view.dart` — hybrid toggle, `_startHybridMode()`, `_stopHybridMode()`, quiz bridge, AppBar/panel theming
- `lib/services/online_session_service.dart` — `startLanBridge(sessionId)`, `stopLanBridge()` static methods; imports LAN services
- `lib/features/online/online_session_view.dart` — `PARTICIPANT_UPDATE {source:'lan'}` handler; "LAN N" badge in teacher layout

---

## Notes
- LAN mode (UDP beacon, local HTTP server, local WS) is Android-only and will never be available on the web app.
- The web app (separate React repo) handles online-only features and has its own phase plan.
- Online and LAN sessions for the same classroom are tracked separately in the DB — attendance and quiz responses are never merged across transports.
- All online API calls go through `CloudApiService` which manages the Sanctum token lifecycle.
