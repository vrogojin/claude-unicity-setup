---
name: deny-agent
description: Deny a remote Claude agent — record it as denied in the registry so its messages are dropped and never surfaced for authorization again.
---

# /deny-agent — Refuse a Remote Agent

Owner-only decision. Records a `denied` entry in the authorized-agents registry for a
remote agent. Denied agents' messages are still received and logged, but they are
classified as `denied`, never enqueued as work items, never acted upon, and never
re-surfaced in the authorization gate.

## Usage

```
/deny-agent <name-or-npub> [reason note]
```

## Instructions

1. If no target was given, show the pending agents so the caller can pick:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" list pending
   ```

2. Apply the denial:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" \
     deny "<name-or-npub>" --note "<optional reason>"
   ```
   If it prints `ERR: no registry entry matches …`, the name/npub is wrong — ask for
   the exact npub.

3. Clear the gate so the pending prompt disappears:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/classify-inbound.sh"
   ```

4. Confirm:
   ```
   Denied <name> (npub1…short). Their messages will be dropped from here on.
   ```

## Note

Denial is reversible: re-run `/authorize-agent <name-or-npub> <caps>` later to grant
access. To wipe an entry entirely, edit the registry file printed by
`bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" path`.
