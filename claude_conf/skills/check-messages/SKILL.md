---
name: check-messages
description: Read and display agent messages from the UNICITY_DEV_AGENTS group and direct messages from the owner.
---

# /check-messages — Read Agent Messages

On-demand skill to read and display messages from the UNICITY_DEV_AGENTS group and direct messages from the owner.

## Instructions

0. Resolve the per-repo state directory (hook state files are namespaced per repo to
   avoid cross-session collisions). Use this `STATE_DIR` for every state-file path below:
   ```bash
   STATE_DIR="$( . "$CLAUDE_PROJECT_DIR/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR" )"
   STATE_DIR="${STATE_DIR:-/tmp/claude}"
   ```

1. Read the agent message state file at `$STATE_DIR/agent-messages.json`.

2. If the state file does not exist or has no messages, attempt a live poll:
   ```bash
   node "$CLAUDE_PROJECT_DIR/../lib/sphere-helper.mjs" check-messages \
     --identity "$CLAUDE_PROJECT_DIR/.claude/agent/identity.json" \
     --config "$CLAUDE_PROJECT_DIR/.claude/agent/config.json"
   ```
   If the helper is not found, try `"$CLAUDE_PROJECT_DIR/lib/sphere-helper.mjs"` instead.

3. Display unread messages grouped by type:

   **Priority Messages (from owner):**
   Show these first, with emphasis. Format each as:
   > **[@owner-nametag]** (timestamp): message body

   **Group Messages (UNICITY_DEV_AGENTS):**
   Format each as:
   > [sender-npub-short] (timestamp): message body

   **Direct Messages:**
   Format each as:
   > DM from [sender] (timestamp): message body

4. After displaying, mark all messages as read by updating the state file:
   ```bash
   jq '.unread = false | .unread_count = 0 | .priority_count = 0 | .messages = [.messages[] | .read = true]' \
     "$STATE_DIR/agent-messages.json" > "$STATE_DIR/agent-messages.json.tmp" \
     && mv "$STATE_DIR/agent-messages.json.tmp" "$STATE_DIR/agent-messages.json"
   ```

5. If there are no messages at all, report: "No messages. Agent inbox is empty."

6. Show a summary line at the end:
   ```
   --- N message(s) displayed, M were priority ---
   ```
