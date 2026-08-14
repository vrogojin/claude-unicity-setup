---
name: redeem-ticket
description: Redeem a one-time invite TICKET from a coordinator/peer — single command that mutually authorizes both sides. Use after setup.sh, or fold it into setup.sh --ticket.
---

# redeem-ticket

Redeem an invite ticket you were given. One command ⇒ you and the issuer end up **mutually
authorized**; nothing to copy back to them.

## Fastest path (brand-new peer)

Fold it into install — a single command past `git clone`:

```bash
./setup.sh <your-project-dir> --ticket 'unicity-ticket:v1.…'
```

## After an existing setup

```bash
bash .claude/hooks/ticket.sh redeem 'unicity-ticket:v1.…'
```

The redeem **verifies the ticket signature and that it was signed by the issuer it names
BEFORE sending anything**, prints who you're about to mutually authorize (issuer, the caps
each side grants, expiry), sends a signed redeem, and waits (~120s) for the issuer's grant —
it polls on its own, so it works **before** the daemon is running. On success it prints
`MUTUAL AUTH OK`.

- The issuer must be reachable on the ticket's relay while you redeem (their daemon up). If
  it times out, the redemption is recorded and finalizes automatically when the grant
  arrives via the daemon — or just re-run the redeem.
- Then: start the daemon and `/consult-coordinator <issuer-name> "what I intend to work on"`.
- Sanity check: the ticket string's issuer/name is shown at redeem time — confirm it's who
  you expect before proceeding (a ticket is a bearer credential).
