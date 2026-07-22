---
name: approve-contact
description: Approve a quarantined new-contact request (unknown npub) into the trust store at team (default) or owner tier. Accepts an npub and optional tier/nametag/label.
---

# /approve-contact — Admit a New Contact

Move an unknown (quarantined) npub into the authorization firewall's contact store
so its messages can surface. This is an **owner decision** — you are acting as the
human half of the authorization firewall (design §3.3).

## What approval DOES and does NOT mean

- **Approval trusts the IDENTITY, not the backlog.** Any messages this npub sent
  while quarantined are **DROPPED on approval** (red-team F7) — ask the sender to
  resend. Approval never replays held peer text as trusted.
- Approval sets a trust **tier** (`team` by default). It does not exempt future
  messages from the semantic firewall — content is still scanned every time.
- `nametag` / `label` you pass are **owner-authored** and constrained
  (`nametag ∈ [a-z0-9-]{1,32}`); a peer can never set them (red-team F4).

## Instructions

1. Determine the npub to approve. It is shown in the pending notice from
   `/check-messages` (the `pending_contact` notice) or in `list-contacts`:
   ```bash
   node "$CLAUDE_PROJECT_DIR/../lib/sphere-helper.mjs" list-contacts \
     --agent-dir "$CLAUDE_PROJECT_DIR/.claude/agent"
   ```
   (If the helper is not at `../lib`, try `"$CLAUDE_PROJECT_DIR/lib/sphere-helper.mjs"`.)

2. Confirm with the user which **tier** (`team` is the safe default; `owner` only
   for the user's own additional devices) and optional owner-authored `nametag` /
   `label`.

3. Approve:
   ```bash
   node "$CLAUDE_PROJECT_DIR/../lib/sphere-helper.mjs" approve-contact "<npub>" \
     --tier team --nametag "<optional-tag>" --label "<optional owner note>" \
     --agent-dir "$CLAUDE_PROJECT_DIR/.claude/agent"
   ```

4. Report the result to the user, including `held_dropped` (the number of
   quarantined messages discarded per F7) and remind them the sender must resend.

## Notes

- Only `team` and `owner` are valid approval tiers; an invalid npub or nametag is
  rejected by the helper.
- To reject instead, use `/deny-contact <npub>`.
