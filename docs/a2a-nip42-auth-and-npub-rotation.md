# A2A Hardening — NIP-42 Relay AUTH + npub Rotation

The A2A coordination fabric (identity, tickets, DM/group transport over Nostr) is understandable
from this **public** repo, and the deployment coordinates (relay URL, group id, coordinator npub)
are committed here. A Fable threat-model (2026‑08‑17) found the residual exposure: an outsider with
only public‑GitHub read + **unauthenticated** Nostr‑subscriber access can **observe and inject**
coordination traffic — harvest every recipient npub from `REQ {kinds:[1059]}` (the gift‑wrap p‑tag
is cleartext for routing), enumerate ticket issuers, and publish protocol‑valid envelopes to any
harvested npub. It cannot read DM content (NIP‑17/44 E2E), impersonate (identity = transport
pubkey), redeem a ticket (256‑bit secret), or make us execute (default‑deny + capability gate).

So the boundary held, but the **coord‑harvest vector** was open. This document describes the two
client‑side prerequisites that close it. **Turning the relay‑side allow‑list on, and enabling the
held A2A peer‑bridge (#525), remain the owner's + security's call** — this repo only ships the
hardening those decisions depend on.

## 1. NIP‑42 relay authentication (client side)

**Fix #1 in the threat‑model** is a NIP‑42 AUTH + pubkey allow‑list **on the relay** — the highest
leverage move: it kills discovery, observation, and injection by unauthenticated parties in one
step. That is owner infra. But it can only be turned on once **our own daemon can authenticate**,
otherwise enabling it strands us.

The SDK's `NostrClient.subscribe()` already answers NIP‑42 AUTH — but the sphere‑helper's hot
paths deliberately use **raw WebSockets** (`fetchEventsRaw`, `watch`, `relayPublish`) because
`subscribe()` never delivers EVENTs against the Unicity relay. Those raw paths did **not**
authenticate, so an auth‑enforcing relay would break every read/write.

`lib/sphere-helper.mjs` now makes the raw paths authenticate **reactively**:

- `makeAuthSigner(nostr, keyManager)` → signs a kind‑**22242** event with our real identity key
  for a given `(relay, challenge)` (NIP‑42).
- `nip42Machine(getWs, relay, signer, onAuthed)` — a per‑socket state machine fed every relay
  frame. On `["AUTH", challenge]` it signs + sends `["AUTH", <event>]`; on the relay's
  `["OK", <authId>, true]` it invokes `onAuthed()` so the caller **re‑issues** its REQ/EVENT (a
  relay drops/`CLOSED auth-required` pre‑auth requests). It answers exactly once and is a no‑op
  when the relay never challenges — transparent against today's non‑auth relay, active the moment
  the owner turns AUTH on.

Threaded through: `check-messages` and `watch` (the daemon's inbox + live path, real key),
`register-nametag` and `resolve-nametag` (backstop), and `relay-publish` / `relay-fetch`
(ticket issue/redeem — `ticket.sh` now passes `--identity`). `send-dm` / group publish use the
SDK client, which already authenticates.

**Why this closes the vector:** once the relay enforces AUTH + a pubkey allow‑list, an
unauthenticated harvester's `REQ` is `CLOSED auth-required` and yields nothing, while our
allow‑listed daemon authenticates and keeps working. Our own pre‑auth REQ leaks nothing new — a
REQ is a subscription to the relay, never rebroadcast to other clients.

**Self‑test:** `test/nip42-auth.test.sh` stands up a relay stub (`test/nip42-relay-stub.mjs`) that
enforces NIP‑42 (schnorr‑verifies the AUTH event echoes its challenge) and proves: WITH an
identity we authenticate and read/publish; WITHOUT one we are gated (0 events / rejected publish);
a forged AUTH (tampered signature) is rejected; both proactive and reactive AUTH orderings work.

## 2. npub rotation (chain‑of‑trust)

**Fix #3** is rotating the exposed npub so a leaked/harvested identifier isn't a durable target.
A rotation announcement is only trustworthy if the **key being retired authorizes its successor** —
otherwise anyone could "rotate" our identity to a key they control. So:

- `sphere-helper rotate-sign --identity <old> --new-npub <npub>` — the **OLD** key signs an
  attestation (kind‑30078 parameterized‑replaceable, `d="npub-rotation"`, `L="unicity:npub-rotation"`,
  `p=<new hex>`, plaintext JSON `{old_npub,new_npub,ts,reason}`) binding old→new.
- `sphere-helper rotate-verify` — verifies the signature **and that `ev.pubkey == old_npub`** (the
  retiring key signed it). Fails closed on a tampered payload or a bystander re‑sign.

`a2a rotate --yes [--reason …] [--no-announce]` orchestrates it: generate the successor, sign the
attestation with the old key, **announce** it (relay‑publish + DM the owner and every authorized
peer, all sent by the old key so recipients can verify), then **swap** `identity.json` — archiving
the old key `0600`, recording the retired npub in `config.previous_npubs`, persisting the
attestation for re‑announce. Destructive → requires `--yes`.

Registry + classifier make the fabric rotation‑aware while preserving **default‑deny**:

- `agent-registry.sh rotate <old> --to <newNpub> [--owner]` — the old entry becomes
  `status="retired"` (capabilities stripped, `rotatedTo` set); the successor is seeded keyed by its
  own hex. **Without `--owner` the successor lands `pending`** (the owner re‑authorizes it); a
  `denied` identity **stays denied** across rotation (no escape into a fresh slot).
- `classify-inbound.sh` verifies an inbound `identity.rotate` attestation, requires the sender to
  be the rotating key (`att.old_hex == from`) **and currently authorized**, then retires the old
  key and seeds the successor pending. Traffic from a `retired` key is dropped inert — a harvested
  old npub is a dead end.

**Clean invalidation of the old npub:** after rotation our daemon uses the new key for all AUTH +
sends, peers that process the attestation re‑point to the successor and drop the retired key, and
on an auth‑enforcing relay the owner removes the old key from the allow‑list. No capability
transfers automatically — the owner re‑authorizes the successor.

**Self‑test:** `test/npub-rotation.test.sh` — attestation verify/forgery, registry rotate
(retire + default‑deny + denied‑stays‑denied), retired‑key drop, `identity.rotate` ingest
(valid / wrong‑sender / unauthorized), and the local `a2a rotate` swap.

## Operational notes

- **Order of operations for the owner:** (1) confirm all authorized peers run this build; (2) turn
  on NIP‑42 AUTH + the pubkey allow‑list on the relay; (3) rotate the exposed coordinator npub
  (`a2a rotate --yes`), re‑authorize the successor on peers, and update the relay allow‑list
  (add the new key, remove the old); (4) restart the daemon (`a2a daemon restart`).
- **Held:** enabling the A2A peer‑bridge (#525) stays gated on owner + security sign‑off. This
  work is the prerequisite, not that decision.
