---
name: team-form
description: Found a goal-scoped team over A2A — become its coordinator, invite authorized peers (Contract-Net), and record the team ledger. Opt-in; nothing runs until you and the invitees join.
---

# /team-form — Found a Team

Creates a **goal-scoped team** and makes this instance its **coordinator** (Contract-Net
initiator-as-manager). Sends a `team.invite` to each candidate peer over the A2A/Nostr
transport and records the team under the durable team store
(`<memory>/team/<teamId>/`). See `docs/team-coordination.md` for the full model.

Requires the Sphere daemon (A2A transport) running to actually deliver invites; without
it, invites are prepared and shown as a dry-run.

## Usage

```
/team-form <goal> <member-npub-or-name> [<member> ...]
```

- `<goal>` — the shared objective (quote it if it has spaces).
- members — each an `npub1…` (or a name already in the registry with a known npub).

## Instructions

Let `TC="$CLAUDE_PROJECT_DIR/.claude/hooks/team-coord.sh"` and
`REG="$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh"`.

1. **Mutual authorization is a prerequisite.** A team runs on the existing default-deny
   registry: for each member you must have **authorized their pubkey** with the team caps,
   and they must authorize yours, or the coordination verbs are dropped. For each member
   not yet authorized, tell the admin to run:
   ```
   /authorize-agent <npub-or-name> team-coordinate,task-bid,knowledge-share
   ```
   (Grant only `team-coordinate` for an observer who should receive coordination + knowledge
   but not bid.) Do not proceed to invite a member you have not authorized — note it and continue with the rest.

2. **Create the team** (a short, stable teamId derived from the goal):
   ```bash
   TEAM="$(printf '%s' "<goal>" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-' | cut -c1-24)-$RANDOM"
   bash "$TC" create "$TEAM" "<goal>" --ttl-hours 168
   ```

3. **Record each member** (registers a peer + adds to the roster). For a raw npub, seed the
   registry peer entry first so replies resolve:
   ```bash
   bash "$REG" upsert-peer --npub "<npub>" --name "<name-if-known>"
   bash "$TC" add-member --team "$TEAM" --npub "<npub>" --name "<name-if-known>"
   ```

4. **Send the invitation** to all members (SIF egress-guarded inside `emit`; honors
   `TEAM_DRY_RUN`). Build the invite envelope and emit:
   ```bash
   INV="$(bash "$TC" envelope "$TEAM" team.invite \
      --payload "$(jq -nc --arg g '<goal>' '{goal:$g, ttlHours:168}')")"
   bash "$TC" emit "$TEAM" "$INV"
   ```

5. **Report** the teamId, the goal, the invited members, and remind the admin that the team
   stays inert until invitees accept (their agents run `/team-work`) and until you run
   `/team-work` to decompose the goal and open the first CFPs.

## Safety

- Founding a team grants nothing on its own — every member is still default-deny and
  capability-scoped; an invite an unauthorized peer sends you is only a *pending
  authorization*, never auto-joined.
- Keep the member set to peers whose owners expect to collaborate on this goal; a team is a
  federation of principals, not one fleet.
