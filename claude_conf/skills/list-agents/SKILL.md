---
name: list-agents
description: List all known remote agents in the authorized-agents registry with their status and granted capabilities.
---

# /list-agents — Show the Authorized-Agents Registry

Displays every remote Claude agent this master-manager instance knows about, with its
status (`authorized` / `pending` / `denied` / `peer`), granted capabilities, and claimed
unicity name.

## Usage

```
/list-agents [status]
```

Optional `status` filters to one of `authorized`, `pending`, `denied`, `peer`.

## Instructions

1. Read the registry:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" list "${1:-}"
   ```

2. Present it as a table, grouped by status. For each agent show:
   - **Name** (claimed unicity name, or `—` if none), **status**, **capabilities**
   - **pubkey** (short) and **npub** if known
   - For `pending` agents: their **intro** text (what they said on first contact)

3. Point out next actions:
   - Pending agents → `/authorize-agent <name-or-npub> <caps>` or `/deny-agent <name-or-npub>`
   - To reach one → `/dm-agent <name-or-npub> <message>`

4. If the registry is empty, report:
   ```
   No agents known yet. The registry is empty (default-deny): any agent that contacts us
   will appear here as `pending` for your authorization.
   ```
