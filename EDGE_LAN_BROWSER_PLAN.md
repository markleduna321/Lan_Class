# Edge-LAN Browser Access — Implementation Plan

> **Goal:** Let devices **without the app** (smart TVs, laptops, any phone) join a
> live classroom by connecting to the teacher's hotspot, opening a **web browser**,
> and viewing the presentation + quizzes — served directly by the app's existing
> Edge-LAN server. No internet, no installation.

---

## Why this is a small, natural addition

The Edge-LAN server (`lib/services/lan_server_isolate.dart`) is **already a full
HTTP + WebSocket server** running in a background isolate on the teacher's device.
It currently serves the Flutter student clients. We only need to add a **browser
client** that speaks the same protocol — the transport, events, quiz scoring, and
attendance plumbing already exist.

### What already exists (reuse as-is)

| Capability | Current endpoint / event |
|---|---|
| HTTP + WebSocket server | `HttpServer.bind(hostIp, 8080)` |
| Real-time channel | WebSocket upgrade on any path |
| Serve presentation file | `GET /file` (currently `Content-Disposition: attachment`) |
| Quiz submission + scoring | `POST /quiz-submit` → returns score/results |
| CORS | `Access-Control-Allow-Origin: *` already set |
| Attendance | `HANDSHAKE {name}` → `StudentConnectedUpdate` records attendance |

### WebSocket protocol (server → client)

| Event | Payload |
|---|---|
| `HANDSHAKE_ACK` | `{status, current_file?, current_quiz?}` |
| `FILE_PRESENTATION_START` | `{filename, mime_type, url:'/file', size_bytes}` |
| `PAGE_CHANGE` | `{page_index}` |
| `QUIZ_START` | `{quiz_id, title, questions:[...]}` |
| `QUIZ_ENDED` | `{}` |
| `PRESENTATION_ENDED` | `{}` |

### WebSocket protocol (client → server)

| Event | Payload |
|---|---|
| `HANDSHAKE` | `{event:'HANDSHAKE', name}` |
| `RAISE_HAND` | `{event:'RAISE_HAND'}` |

**A browser client just needs to speak this exact JSON protocol over
`ws://<host>:8080/` and render the file from `/file`.**

---

## What we add

1. A self-contained **web client** (`index.html` with inline JS + CSS, vanilla —
   no framework, so it runs on old/limited smart-TV browsers).
2. Two new HTTP routes on the existing server:
   - `GET /`      → serve the web client HTML.
   - `GET /view`  → serve the current presentation **inline** (so browsers render
     PDFs/images directly, instead of downloading like `/file`).
3. A way to hand the bundled HTML string to the background isolate.
4. A teacher-facing **connection URL + QR code** so TVs/laptops can find the page.

---

## Architecture

```
        Teacher device (hotspot 192.168.43.1)
        ┌───────────────────────────────────────────┐
        │  Flutter app                               │
        │   └─ LAN server isolate (HttpServer:8080)  │
        │        • GET /        → web client HTML     │  ← NEW
        │        • GET /view    → presentation inline │  ← NEW
        │        • GET /file    → file (Flutter dl)   │
        │        • WS  /        → live events          │
        │        • POST /quiz-submit                   │
        └───────────────────────────────────────────┘
             ▲              ▲               ▲
   ┌─────────┘        ┌─────┘         ┌─────┘
   │ Flutter student  │ Smart TV      │ Laptop browser
   │ (app, WS)        │ browser (WS)  │ (WS)              ← NEW clients
```

**Asset delivery to the isolate:** background isolates can't read `rootBundle`.
So the **main isolate** loads the web client string via
`rootBundle.loadString('assets/lan_web/index.html')` and passes it into the server
isolate — either as a new field on `StartLanServerCommand` or via a new
`SetWebClientCommand`. The isolate holds it in memory and serves it at `GET /`.

**Single-file web client:** to avoid multiple asset routes and keep TV
compatibility simple, JS + CSS are **inlined** into one `index.html`. One asset,
one route.

---

## Presentation rendering — the one real design decision

Browsers handle the two file types differently:

- **Images** (`image/*`) → trivial: `<img src="/view">`. Works on every browser/TV.
- **PDFs** → native browser PDF viewers **cannot be reliably told "go to page N"**
  across browsers (especially smart-TV browsers). Two options for slide sync:

| Option | How | Pros | Cons |
|---|---|---|---|
| **A. PDF.js** | Bundle PDF.js; render pages to a `<canvas>`; `PAGE_CHANGE` → render that page | Exact page sync, crisp | ~1 MB JS; heavier on old TV browsers |
| **B. Server rasterize** | App renders each PDF page → PNG (Syncfusion can do this); serve `GET /slide/{i}`; `PAGE_CHANGE` → swap `<img>` | Lightest client; works on any TV | Needs on-device PDF→image render + caching |

**Recommendation:** ship **whole-file inline view first** (Phase B), then add
**Option B (server-rasterized image slides)** in Phase D — it gives the best
smart-TV compatibility and keeps the browser client dumb/fast.

---

## Phases

### Phase A — Serve a static page from the LAN server  ✅ DONE
**Deliverables**
- `assets/lan_web/index.html` — placeholder page ("Connected — waiting for
  presentation").
- Register `assets/lan_web/` in `pubspec.yaml`.
- Main isolate loads the HTML string and passes it to the server isolate
  (new field on `StartLanServerCommand` **or** `SetWebClientCommand`).
- Isolate serves it at `GET /` (replace the current
  "AsuraTECH Edge Node Active" plain-text response).
- Add `GET /view` → serves the current file with `Content-Disposition: inline`
  and the correct content-type (reuses `servedFilePath`).

**Test:** connect a laptop to the hotspot, browse to `http://<hostIp>:8080/`,
see the page.

---

### Phase B — Live presentation in the browser  ✅ DONE
**Deliverables** (all inside `index.html` JS)
- Ask for a display name (prompt once, cache in `localStorage`).
- Open `ws://<location.host>/`, send `HANDSHAKE {name}`.
- On `HANDSHAKE_ACK` / `FILE_PRESENTATION_START`:
  - image → `<img src="/view">`
  - pdf   → `<iframe src="/view">` (whole document, scrollable)
- On `PRESENTATION_ENDED` → return to "waiting" screen.
- Auto-reconnect with backoff if the socket drops.
- Connection status indicator.

**Result:** TVs/laptops see the presentation live; teacher's existing
"Present file" flow drives them with zero extra teacher steps. Attendance for
browser viewers is recorded automatically via the HANDSHAKE name.

---

### Phase C — Page-accurate slide sync  ⭐ CORE  ✅ DONE
**Deliverables** (server-side rasterization)
- When the teacher presents a PDF, the **main isolate** rasterizes each page to a
  PNG (`printing` package) into a temp dir and passes the dir + page count to the
  server isolate.
- Isolate serves `GET /slide/{index}` from the cached PNGs.
- Web client shows `<img src="/slide/{i}">` and swaps it on each `PAGE_CHANGE` —
  pixel-accurate, tiny JS, works on any TV, fully offline.
- Image presentations (single `image/*`) skip rasterization and use `GET /view`.
- Fallback to whole-file `<iframe src="/view">` if rasterization is unavailable.

**Result:** the browser view follows the teacher page-by-page, matching the app
students, and renders reliably even on weak TV browsers.

---

### Phase D — Teacher discovery UX  ✅ DONE
**Deliverables**
- On the teacher dashboard, when the LAN server is active, show:
  - the join URL (`http://<hostIp>:8080/`) in large text, and
  - a **QR code** encoding that URL (`qr_flutter`).
- Short "How to join from a TV / laptop" hint.

**Result:** teachers can point a TV browser or laptop at the URL/QR instantly.

---

### Phase E — Polish  ◑ PARTIAL
- Browser participants appear in the live participant list (tagged "web"). ⏳ later
- Responsive, TV-friendly dark layout (large fonts, high contrast). ✅
- **Raise hand** button in the browser (sends `RAISE_HAND`). ✅
- Optional **room PIN** gate on the web client. ⏳ optional / later

---

## Files touched / added

| File | Change |
|---|---|
| `assets/lan_web/index.html` | **New** — self-contained web client (HTML+JS+CSS) |
| `pubspec.yaml` | Register `assets/lan_web/` |
| `lib/services/lan_server_messages.dart` | Add `SetWebClientCommand` (or field on start) + `ServeSlideCommand` (Phase D) |
| `lib/services/lan_server_isolate.dart` | Serve `GET /`, `GET /view`, `GET /slide/{i}`; hold web HTML string |
| `lib/features/classroom/teacher_dashboard_view.dart` | Load web asset + pass to isolate; show URL + QR (Phase E) |

---

## Risks & Notes

- **Smart-TV browser variance:** old TV browsers (Tizen/webOS) have quirky
  WebSocket + PDF support. Option B (image slides) sidesteps PDF rendering issues.
  Keep the JS ES5-friendly (no modern syntax) for maximum compatibility.
- **No auth on the LAN:** anyone on the hotspot can open the page. This matches the
  open-classroom model; Phase F adds an optional PIN if needed.
- **Port 8080 must be reachable** on the hotspot interface (already bound there).
- **Performance:** serving a handful of browser clients + app clients from one
  device is fine; image slides (Phase D) are cached, so rasterization happens once
  per page.
- **Hotspot addressing:** the join URL uses the host IP already shown on the
  dashboard (`http://192.168.43.1:8080/`).

---

## Recommended Order

1. **Phase A** — serve a static page (proves the pipeline).
2. **Phase B** — live presentation (the core ask).
3. **Phase C** — quizzes.
4. **Phase E** — URL + QR (small, high value; can slot in right after B).
5. **Phase D** — page-accurate slide sync.
6. **Phase F** — polish / PIN / raise-hand.

Each phase is independently shippable and leaves the LAN server fully working.
