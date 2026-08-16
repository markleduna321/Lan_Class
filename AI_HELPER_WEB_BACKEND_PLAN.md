# AI Helper Web Backend Plan

## Goal

Make the AI Helper in the Flutter app use a web backend endpoint instead of calling OpenAI directly from the client. The backend will hold the OpenAI key in its environment and return AI responses securely.

## Requirements

1. The AI Helper chat is temporary.
   - Messages should only exist for the current session.
   - They should not be persisted to the local database.
   - They should be cleared when the app session ends or the user signs out.

2. The AI Helper should use a backend endpoint.
   - Flutter app sends the prompt and optional classroom context.
   - Web backend calls OpenAI with the key from `.env`.
   - Flutter app receives the reply and displays it.

3. The backend must keep the OpenAI key private.
   - Never expose the key to the Flutter client.
   - The key should live only in the web app server environment.

4. The AI Helper should remain scoped to classroom materials.
   - The backend should enforce that the answer is based on the provided classroom context.
   - It should refuse unrelated questions.

5. The AI Helper should support optional broader web relevance only when the user explicitly enables it.
   - This should be a lightweight supplemental context feature, not a general unrestricted web chat.

## Recommended Web Backend Flow

### Flutter request payload

Send a POST request to the web backend endpoint, for example:

```json
{
  "prompt": "Explain the lesson about networking",
  "materials": [
    {
      "classroom_name": "Networking 101",
      "original_name": "Lecture 1.pdf"
    }
  ],
  "studentMaterials": [],
  "allowWebSearch": false
}
```

### Backend response payload

Return:

```json
{
  "reply": "A classroom-grounded answer here"
}
```

### Backend behavior

- Read `OPENAI_API_KEY` from `.env`
- Build the prompt using the provided classroom materials
- Send the request to OpenAI
- Return the reply to Flutter

## Suggested Backend Endpoint

Use a route like:

```text
POST /api/ai-helper
```

## Temporary Chat Behavior

### Client-side behavior

- Keep chat messages in memory only.
- Do not insert them into SQLite.
- Clear them on:
  - sign out
  - app restart
  - switching away from the AI Helper view if the app is designed to reset on session end

### Suggested implementation rule

The AI chat state should be ephemeral and should not survive beyond the active app session.

## Suggested Backend Prompt Guard

The backend should enforce the same rules as the Flutter-side guard:

- Only answer questions related to the classroom materials provided.
- If the question is unrelated, return a short refusal message.
- If `allowWebSearch` is enabled, allow only a minimal relevance note, not a general unrestricted answer.

## Suggested Web App Files

If the web app is Laravel-style, the implementation would likely involve:

- a controller for the AI endpoint
- a route definition in `routes/api.php`
- `.env` entry for `OPENAI_API_KEY`

Example environment entry:

```env
OPENAI_API_KEY=your_openai_key_here
```

## Flutter Integration Notes

The Flutter app should:

- stop calling OpenAI directly from the client
- call the web endpoint instead
- display the returned `reply`
- clear the in-memory chat state when the session ends

## Acceptance Criteria

- The Flutter AI Helper works through the web backend
- The OpenAI key is stored only on the web server
- Students cannot see or edit the shared key
- The AI Helper chat is temporary and does not persist after session end
- The assistant remains grounded to classroom materials
