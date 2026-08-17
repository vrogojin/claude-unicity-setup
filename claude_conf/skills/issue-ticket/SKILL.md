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
  --name "dev-2 peer"        # [--bind <npub>] to lock it to one known npub
# Defaults: --caps consult,claim-area (least privilege) · --ttl 15m (minutes, not a day).
# Widen deliberately, e.g. --caps consult,claim-area,task-bid --ttl 2h, when you mean to.
# [--v1] emits the legacy long self-contained format for peers on pre-v2 framework code.
```

It prints a single short line `ut2_…` (47 chars — paste-proof). The caps/expiry/issuer
authorization is a **signed event published to the relay** at issue time (its content is
encrypted under a key derived from the ticket secret, so the relay learns nothing but your
pubkey and a hash); if the relay publish fails, the issue fails loudly and nothing is
recorded. That short string **is a bearer credential**:
- Send it over a **private** channel (DM/email), not a public one.
- Default TTL is 15m and default caps are the two non-destructive coordination caps
  (`consult,claim-area`); widen only when you mean to, and add `--bind <npub>` when you
  already know the peer's npub (closes the bearer window entirely).
- Leaked? `bash .claude/hooks/ticket.sh revoke <tid>` (the tid prints in the issue log).
- `bash .claude/hooks/ticket.sh list [pending|redeemed]` shows your ledger.

## What the colleague does

One command after cloning: `./setup.sh <their-project> --ticket 'ut2_…'`.
When they redeem, you auto-authorize them with `--caps`, they auto-authorize you with
`--grant-back`, and any coordination messages they already sent replay through the gate.

Caps are validated against the registry enum; a destructive cap only permits *asking* —
execution still needs owner confirmation.
