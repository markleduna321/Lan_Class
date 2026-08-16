# Online Attendance — Backend Requirements
**For the Web / Laravel Team**

Server base: `https://itcomm.asuratechsolutions.com`
Auth: Laravel Sanctum bearer tokens (`Authorization: Bearer {token}` + `Accept: application/json`)

---

## Problem

Attendance for **LAN sessions** is recorded locally on the teacher's device (SQLite).
When students join over the local network, the teacher's app writes an attendance
row per student per day.

**Online sessions have no equivalent.** When a student joins an online classroom
(`POST /api/classrooms/{id}/join`), the backend registers them as a live participant,
but:

1. No **persistent attendance record** is created (student + classroom + date + timestamp).
2. `GET /api/sessions/{id}/participants` only returns the **current live list**, not a
   historical log. Once the session ends, that data is gone.
3. The teacher cannot review **who attended on which date** for online sessions.

The mobile app already has an **Attendance Log** screen (table view: students × dates).
It currently only shows LAN attendance. To show online attendance, the backend must
**persist attendance** and expose it via a **retrieval endpoint**.

---

## Required Work

### 1. Persist attendance when a student joins

On `POST /api/classrooms/{id}/join`, in addition to registering the participant,
**create or update** an attendance record:

```
Table: classroom_attendance

| Column        | Type      | Notes                                        |
|---------------|-----------|----------------------------------------------|
| id            | CHAR(36)  | UUID, primary key                            |
| classroom_id  | CHAR(36)  | FK → classrooms.id                           |
| session_id    | CHAR(36)  | FK → sessions.id (nullable if joined w/o session) |
| user_id       | BIGINT    | FK → users.id                                |
| student_name  | VARCHAR   | denormalised for fast display                |
| session_date  | DATE      | e.g. 2026-07-13 (server date at join time)   |
| joined_at     | TIMESTAMP | first join time for this date                |
| left_at       | TIMESTAMP | nullable — last known leave time             |
| created_at    | TIMESTAMP |                                              |
| updated_at    | TIMESTAMP |                                              |
```

**De-duplication rule:** One attendance row **per user per classroom per `session_date`**.
If the student re-joins the same day, update `joined_at` only if not already set — do
**not** create a duplicate row.

```sql
CREATE TABLE classroom_attendance (
  id           CHAR(36)     PRIMARY KEY,
  classroom_id CHAR(36)     NOT NULL,
  session_id   CHAR(36)     NULL,
  user_id      BIGINT       NOT NULL,
  student_name VARCHAR(100) NOT NULL,
  session_date DATE         NOT NULL,
  joined_at    TIMESTAMP    NULL,
  left_at      TIMESTAMP    NULL,
  created_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_attendance (classroom_id, user_id, session_date),
  FOREIGN KEY (classroom_id) REFERENCES classrooms(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id)      REFERENCES users(id)       ON DELETE CASCADE
);
```

Laravel controller sketch for the join handler:

```php
ClassroomAttendance::firstOrCreate(
    [
        'classroom_id' => $classroom->id,
        'user_id'      => $request->user()->id,
        'session_date' => now()->toDateString(),
    ],
    [
        'id'           => (string) Str::uuid(),
        'session_id'   => $activeSession?->id,
        'student_name' => $request->user()->name,
        'joined_at'    => now(),
    ]
);
```

---

### 2. Attendance retrieval endpoint (NEW)

The teacher's app needs to fetch attendance to display it in the Attendance Log table.

#### GET `/api/classrooms/{id}/attendance`
**Protected** (teacher / classroom owner only)

```
Optional query params:
  from   (date)  — filter session_date >= from  (e.g. 2026-07-01)
  to     (date)  — filter session_date <= to
```

```json
// Response 200
{
  "data": [
    {
      "id": "att-uuid",
      "classroom_id": "classroom-uuid",
      "session_id": "session-uuid",
      "user_id": 42,
      "student_name": "Juan Dela Cruz",
      "session_date": "2026-07-13",
      "joined_at": "2026-07-13T10:05:00.000000Z",
      "left_at": null
    }
  ]
}
```

> The app maps this into a **students × dates** presence table. The only fields it
> strictly needs are `student_name` and `session_date`. `joined_at` / `left_at` are
> used for detail rows.

---

### 3. (Optional) Record leave time

If you want accurate `left_at` values, add an endpoint the app can call when a
student closes the session lobby:

#### POST `/api/classrooms/{id}/leave`
**Protected**

```json
// Response 200
{ "message": "Attendance updated." }
```

Handler sets `left_at = now()` on today's attendance row for the user.
This is **optional** — the app currently does not send leave events. Skip if not needed.

---

## Summary Checklist

| # | Task | Priority |
|---|------|----------|
| 1 | Create `classroom_attendance` table | 🔴 Required |
| 2 | Record attendance in `POST /api/classrooms/{id}/join` (firstOrCreate per user/classroom/date) | 🔴 Required |
| 3 | Add `GET /api/classrooms/{id}/attendance` retrieval endpoint | 🔴 Required |
| 4 | (Optional) `POST /api/classrooms/{id}/leave` for `left_at` | 🟢 Optional |

---

## Notes for the App Team (internal — not backend)

Once the endpoint above exists, the Flutter app must:
- Fetch `GET /api/classrooms/{id}/attendance` when the teacher opens the Attendance Log.
- Merge those rows with local LAN attendance (same `student_name` / `session_date` shape).
- Tag online rows (e.g. source = "online") so the UI can distinguish LAN vs online if desired.

This app-side work is tracked separately and is unblocked once endpoints #2 and #3 ship.
