---
name: issue-ticket
description: Issue a one-time, expiring, signed invite TICKET so a colleague can join with a single command (mutual auto-authorization). Symmetric — anyone can issue.
---

# issue-ticket

Mint a copy-pasteable **one-time invite ticket**. Whoever redeems it (with `setup.sh --ticket`
or `/redeem-ticket`) ends up **mutually authorized** with you — no npub-copying, no manual
`authorize` step on either side.

## Run

```bash
bash .claude/hooks/ticket.sh issue \
  --caps team-coordinate,task-bid,knowledge-share,self-directed,consult,claim-area \
  --grant-back consult,claim-area \
  --ttl 24h \
  --name "dev-2 peer"        # [--bind <npub>] to lock it to one known npub
```

It prints a single line `unicity-ticket:v1.…`. That string **is a bearer credential**:
- Send it over a **private** channel (DM/email), not a public one.
- Default TTL is 24h; use a short one for high-value caps and add `--bind <npub>` when you
  already know the peer's npub (closes the bearer window entirely).
- Leaked? `bash .claude/hooks/ticket.sh revoke <tid>` (the tid prints in the issue log).
- `bash .claude/hooks/ticket.sh list [pending|redeemed]` shows your ledger.

## What the colleague does

One command after cloning: `./setup.sh <their-project> --ticket 'unicity-ticket:v1.…'`.
When they redeem, you auto-authorize them with `--caps`, they auto-authorize you with
`--grant-back`, and any coordination messages they already sent replay through the gate.

Caps are validated against the registry enum; a destructive cap only permits *asking* —
execution still needs owner confirmation.
