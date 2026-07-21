---
name: deny-contact
description: Deny/block an npub — moves it to the blocked list and purges any quarantined backlog. Accepts an npub.
---

# /deny-contact — Block a Contact

Deny a contact request (or block an existing contact). The npub is added to the
`blocked` list and any quarantined messages from it are purged. Blocked senders
are dropped and audit-logged only — they never surface (design §3.1).

## Instructions

1. Determine the npub to deny (from the `/check-messages` pending notice or
   `list-contacts`).

2. Block it:
   ```bash
   node "$CLAUDE_PROJECT_DIR/../lib/sphere-helper.mjs" deny-contact "<npub>" \
     --agent-dir "$CLAUDE_PROJECT_DIR/.claude/agent"
   ```
   (If the helper is not at `../lib`, try `"$CLAUDE_PROJECT_DIR/lib/sphere-helper.mjs"`.)

3. Confirm to the user that the npub is now blocked and its quarantined backlog
   was purged.

## Notes

- Blocking is reversible only by re-approving with `/approve-contact` (which
  removes it from the blocked list).
- Denying never reveals or renders the blocked sender's message content.
