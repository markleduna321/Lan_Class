# Aura Vote Backend Handoff

Updated: 2026-08-08  
Target: Laravel backend team

## Problem Summary

When forum upvotes/downvotes happen, the author's aura value is being overwritten by a small forum score value (for example 99999 becoming 10).

Root issue:
- Vote endpoints are likely assigning aura_score from vote_score/reputation snapshots.
- Aura should be incremented/decremented by vote delta, not overwritten.

## Required Behavior

1. Keep post or response vote score logic as-is (delta-based).
2. Update author aura_score only by vote delta.
3. Never assign aura_score = vote_score or aura_score = reputation_score.
4. Run vote and aura updates in one DB transaction with row locks.
5. Return separate fields in API response:
- post_vote_score or response_vote_score
- author_aura_score

## Data Model Assumptions

- users table has aura_score (integer, default 0).
- forum_post_votes has unique pair (post_id, user_id).
- forum_response_votes has unique pair (response_id, user_id).

## Delta Rules

Vote transition delta = new_vote - old_vote where votes are -1, 0, +1.

Examples:
- 0 to +1 = +1
- +1 to 0 = -1
- 0 to -1 = -1
- -1 to +1 = +2
- +1 to -1 = -2

## Reference Service (Post Vote)

```php
<?php

namespace App\Services;

use App\Models\ForumPost;
use App\Models\ForumPostVote;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use InvalidArgumentException;

class ForumVoteService
{
    public function applyPostVote(int $postId, int $voterId, int $requestedVote): array
    {
        if (!in_array($requestedVote, [-1, 0, 1], true)) {
            throw new InvalidArgumentException('Vote must be -1, 0, or 1.');
        }

        return DB::transaction(function () use ($postId, $voterId, $requestedVote) {
            $post = ForumPost::query()->lockForUpdate()->findOrFail($postId);

            $vote = ForumPostVote::query()
                ->where('post_id', $post->id)
                ->where('user_id', $voterId)
                ->lockForUpdate()
                ->first();

            $oldVote = $vote?->vote ?? 0;
            $newVote = $oldVote === $requestedVote ? 0 : $requestedVote;
            $delta = $newVote - $oldVote;

            if ($newVote === 0) {
                if ($vote) {
                    $vote->delete();
                }
            } else {
                if (!$vote) {
                    $vote = new ForumPostVote();
                    $vote->post_id = $post->id;
                    $vote->user_id = $voterId;
                }
                $vote->vote = $newVote;
                $vote->save();
            }

            if ($delta !== 0) {
                $post->increment('vote_score', $delta);
            }

            // Update author aura by delta only (no overwrite)
            if ($delta !== 0 && (int)$post->author_id !== $voterId) {
                User::query()
                    ->whereKey($post->author_id)
                    ->lockForUpdate()
                    ->increment('aura_score', $delta);
            }

            $post->refresh();
            $authorAura = User::query()->whereKey($post->author_id)->value('aura_score');

            return [
                'post_id' => $post->id,
                'user_vote' => $newVote,
                'vote_score' => (int)$post->vote_score,
                'author_aura_score' => (int)($authorAura ?? 0),
            ];
        });
    }
}
```

## Reference Service (Response Vote)

```php
<?php

namespace App\Services;

use App\Models\ForumResponse;
use App\Models\ForumResponseVote;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use InvalidArgumentException;

class ForumResponseVoteService
{
    public function applyResponseVote(int $responseId, int $voterId, int $requestedVote): array
    {
        if (!in_array($requestedVote, [-1, 0, 1], true)) {
            throw new InvalidArgumentException('Vote must be -1, 0, or 1.');
        }

        return DB::transaction(function () use ($responseId, $voterId, $requestedVote) {
            $response = ForumResponse::query()->lockForUpdate()->findOrFail($responseId);

            $vote = ForumResponseVote::query()
                ->where('response_id', $response->id)
                ->where('user_id', $voterId)
                ->lockForUpdate()
                ->first();

            $oldVote = $vote?->vote ?? 0;
            $newVote = $oldVote === $requestedVote ? 0 : $requestedVote;
            $delta = $newVote - $oldVote;

            if ($newVote === 0) {
                if ($vote) {
                    $vote->delete();
                }
            } else {
                if (!$vote) {
                    $vote = new ForumResponseVote();
                    $vote->response_id = $response->id;
                    $vote->user_id = $voterId;
                }
                $vote->vote = $newVote;
                $vote->save();
            }

            if ($delta !== 0) {
                $response->increment('vote_score', $delta);
            }

            if ($delta !== 0 && (int)$response->author_id !== $voterId) {
                User::query()
                    ->whereKey($response->author_id)
                    ->lockForUpdate()
                    ->increment('aura_score', $delta);
            }

            $response->refresh();
            $authorAura = User::query()->whereKey($response->author_id)->value('aura_score');

            return [
                'response_id' => $response->id,
                'user_vote' => $newVote,
                'vote_score' => (int)$response->vote_score,
                'author_aura_score' => (int)($authorAura ?? 0),
            ];
        });
    }
}
```

## Controller Contract (Recommended)

Return distinct metrics:

```json
{
  "message": "Vote updated.",
  "data": {
    "post_id": 123,
    "user_vote": 1,
    "vote_score": 14,
    "author_aura_score": 100000
  },
  "post_vote_score": 14,
  "author_aura_score": 100000
}
```

Do the same shape for response votes.

## Must-Remove Anti-Patterns

Search and remove any logic that does this:

- aura_score = vote_score
- aura_score = reputation
- aura_score = computed forum score snapshot

Aura must be changed only by explicit increments/decrements (or dedicated admin actions).

## Migration / Schema Checks

- Ensure users.aura_score exists and is integer default 0.
- Ensure unique indexes:
  - forum_post_votes (post_id, user_id)
  - forum_response_votes (response_id, user_id)

## Test Checklist (Backend)

1. Post vote transitions:
- 0 to +1 gives aura +1
- +1 to 0 gives aura -1
- 0 to -1 gives aura -1
- -1 to +1 gives aura +2

2. Response vote transitions:
- same transitions and deltas as post votes

3. Self-vote rules:
- if self-votes are blocked, confirm 403/validation
- if allowed by business rule, still avoid unintended aura inflation

4. Concurrency:
- rapid repeated vote requests keep consistent final aura

5. Regression:
- manual aura updates in DB are preserved; next vote adds delta, not reset

## Quick Production Verification

After deploy:

1. Set a test user's aura_score manually (for example 99999).
2. Upvote their post once.
3. Confirm aura_score becomes 100000, not 10.
4. Remove upvote.
5. Confirm aura_score returns to 99999.

## Client Note

Flutter client sends only vote intent:
- vote: -1, 0, 1

Client does not send aura_score updates and should not be used as aura source-of-truth.
