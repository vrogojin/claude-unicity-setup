# One-Time Invite Tickets — single-command mutual onboarding

**Status:** design (authoritative) · **Scope:** `claude_unicity_setup` A2A coordination framework
**Depends on:** the default-deny agent registry (`agent-registry.sh`), the peer coordination
engine (`remote-coord.sh`), the inbound router (`classify-inbound.sh`), the Sphere/Nostr
transport (`lib/sphere-helper.mjs`, `lib/sphere-daemon.mjs`), SIF (`sif-guard.sh`), and the
pre-authorize-by-npub + deferred-replay work (#14).

---

## 1. Problem

Onboarding a new peer today is many manual steps across two humans:

```
peer:        clone repo → ./setup.sh <project>   (mints identity, installs hooks/skills)
peer:        copy the printed npub, send it to the coordinator operator out-of-band
coordinator: onboard-teammate.sh <npub> --name X (pre-authorize)
peer:        start sphere-daemon.mjs
peer:        /consult-coordinator <coord-npub> …
```

Both sides do manual work, both sides can typo an npub, and authorization is
**one-directional**: the coordinator authorizes the peer; the peer merely *trusts* the
coordinator npub pasted into the invite blurb (nothing in the peer's registry records or
gates it).

## 2. Feature

A **one-time-use, expiring, signed invite ticket**. Either side issues it; the other side
redeems it with a single command; both end up **mutually authorized** with the agreed
capabilities — zero further manual steps on either side.

```
issuer:   ticket.sh issue --caps consult,claim-area --ttl 2h --name dev-2
          → prints  ut2_pQ7hT…47 chars…   (one short line; the signed authorization
            event is published to the relay — see §3.0)

redeemer: ./setup.sh <project> --ticket 'ut2_pQ7hT…'
          (or, post-setup:  ticket.sh redeem 'ut2_pQ7hT…'  /  /redeem-ticket)

end state: issuer registry:   redeemer hex → authorized, caps = ticket.caps
           redeemer registry: issuer hex   → authorized, caps = ticket.grantBack
           any coordination envelopes the redeemer sent earlier replay automatically
           (deferred-replay #14 fires on the authorize).
```

**Symmetric by construction**: "issuer" is just whoever ran `issue`. Coordinator→peer and
peer→peer are the same flow; there is no coordinator-specific state.

### Design stance: why a hook may auto-authorize here

Everything else in this framework is "ingest records, a skill + admin decides". A ticket
does **not** violate that: the admin decision happens **at issue time** — running
`ticket.sh issue --caps …` *is* the owner's authorization act, exactly like
`onboard-teammate.sh <npub>` pre-authorizes today. Redemption merely **binds that
already-made decision to a concrete pubkey** (the transport-authenticated sender of the
redeem message). Same trust model, moved one step earlier and made replay/race-safe.

---

## 3. Ticket formats

### 3.0 v2 — short relay-backed tickets (current default)

v1's string self-contained the whole signed event (~1.1 KB) — copy-paste routinely mangled
it. v2 splits the two roles the string was serving:

```
ticket string  =  ut2_<43 alphanumeric chars>          (47 chars total, ≤64)
                  → ONLY a bearer secret: 43 uniform [A-Za-z0-9] chars from /dev/urandom
                    (43·log2(62) ≈ 256 bits — same strength as v1's 32-byte secret)

authorization  =  issuer-signed kind-30777 event PUBLISHED to the relay at issue time,
                  addressable by  d = SHA-256(secret)  (hex), with a NIP-40
                  ["expiration", exp] tag. content = base64url( 12-byte nonce ‖
                  AES-256-GCM(key, payload-JSON) ‖ 16-byte tag ) where
                  key = HKDF-SHA256(ikm=secret, salt="unicity-ticket-v2",
                  info="content-enc") and AAD = "ut2|30777|<d>".
```

The payload inside the encrypted content is the v1 payload **minus `secret`** plus
`{v:2, sh:<d>, tid:"t"+d[0:12]}` (the helper derives `sh`/`tid` from the secret itself, so
the commitment cannot drift from what is signed). Because the content is encrypted under a
secret-derived key, the public relay learns only the issuer pubkey and the hash — never
caps/grantBack/bind/label — restoring the metadata privacy v1 had by never touching a relay.

**Issue** (`ticket.sh issue`, v2 default; `--v1` keeps the legacy emit): mint secret →
`ticket2-sign` → `relay-publish` and **wait for the relay's OK** (publish failure fails the
issue loudly and records nothing) → record hash-only ledger row (`v:2`, `eventId`, `relay`)
→ print `ut2_<secret>`.

**Redeem** (`ticket.sh redeem <ut2_…> [--relay url]`): shape-check the string (mangled
paste dies with a clear reason) → `d = SHA-256(secret)` → `relay-fetch` kind-30777 events by
`#d` → `ticket2-verify` picks the ONE candidate passing the full chain:

1. `kind == 30777` and the `d` tag equals `SHA-256(secret)` (the tag is signed under NIP-01);
2. the schnorr signature verifies over the recomputed NIP-01 id;
3. the content decrypts under the secret-derived key (GCM auth; AAD binds kind+d) — only
   the holder of the right secret gets a payload at all;
4. `payload.sh == d` and `payload.tid == "t"+d[0:12]` (hash commitment);
5. `payload.iss` decodes to `event.pubkey` — an attacker who copies the ciphertext+tags
   into an event signed by their own key fails exactly here (kind-3xxxx addresses are
   per-author, so they can never *replace* the issuer's event either);
6. back in `ticket.sh`: `payload.v == 2`, `exp` in the future, caps within the known set.

From there the flow is **identical to v1** (§6): show the mutual-grant summary, record the
redemption locally, send the signed `ticket.redeem {tid, secret}` DM to the issuer, poll for
the grant. The issuer-side ingest (atomic consume, bind, rate limit, grant-back) is shared
verbatim between the formats — the issuer's ledger, not the relay event, remains the only
thing that authorizes; a relay event with no matching `pending` ledger row is inert, which
is also why `revoke` stays a purely local act.

Relay dependency: redemption now needs one relay *read* before the redeem DM — the same
relay the redeem DM itself needs, so no new availability class. A fetch failure or empty
result fails closed with the likely causes spelled out (connectivity, expired+relay-reaped,
non-default relay ⇒ `--relay`). Tickets issued with `--relay <url>` must be redeemed with
the same `--relay` (the string no longer carries relay hints; issue prints a warning).

### 3.1 v1 payload (legacy, canonical JSON, minified, sorted keys)

```json
{
  "v": 1,
  "tid": "t8f3a1c92be07",
  "iss": "npub1abc…",
  "issName": "<coordinator-nametag>",
  "relays": ["wss://nostr-relay.testnet.unicity.network"],
  "secret": "8_Qy1u-…43-chars-base64url…",
  "caps": ["self-directed", "consult", "claim-area"],
  "grantBack": ["self-directed", "consult", "claim-area"],
  "exp": 1765432100,
  "bind": "",
  "label": "dev-2 peer",
  "scope": { "<consumer-key>": { "…": "…" } }
}
```

`scope` is **optional** and present only when the ticket was issued with `--scope` (§3.1.1);
a ticket without it is byte-identical to a pre-scope one.

| field | meaning |
|---|---|
| `v` | format version tag; redeemers hard-fail on unknown versions (fail closed) |
| `tid` | ticket id: `"t" + sha256(secret)[0:12]` — derived, so it can be printed/logged **without** revealing the secret, and issuer + redeemer independently compute the same id |
| `iss` | issuer npub — where the redeem is sent, and the ONLY identity whose `ticket.grant` the redeemer will accept |
| `issName` | display label / Unicity nametag hint (never a security boundary) |
| `relays` | relay(s) to reach the issuer on; first entry is used for the redeem send + grant poll |
| `secret` | 32 random bytes (`/dev/urandom` via `openssl rand` fallback `head -c32 /dev/urandom`), base64url — the one-time bearer secret. **The issuer never stores this**; only its sha256 |
| `caps` | capabilities the issuer will grant the redeemer (validated against `AGENT_CAPABILITIES` at issue time) |
| `grantBack` | capabilities the redeemer is asked to grant the issuer (defaults to `caps`); the redeemer displays them at redeem time and uses **its locally-stored copy** when granting — never the wire payload |
| `exp` | unix expiry; default now + 15m (`--ttl 15m`, accepts `30s`/`30m`/`24h`/`7d`) |
| `bind` | optional: npub that alone may redeem (`--bind <npub>`); checked against the **transport-authenticated sender hex**, not any claimed field |
| `label` | free-text label for the issuer's ledger |
| `scope` | **optional** (§3.1.1) opaque authorization detail carried for the consuming application: `--scope '<json-object>'`. The framework validates only its *shape*, never its meaning |

### 3.1.1 `scope` — an opaque, signed authorization detail (optional)

`caps` is a **closed, framework-owned enum** (`AGENT_CAPABILITIES`): it answers *which verbs*
a peer may use, and every value must be one the framework already knows. That is the right
shape for agent-to-agent coordination and the wrong shape for a consumer that needs to say
*over which subset of things* — which projects, which entities, which budget. Encoding that
in `caps` would mean pushing application vocabulary into a framework enum every time a
consumer grows a new dimension.

So a ticket may carry one extra, **optional** field:

```bash
ticket.sh issue --caps deck --ttl 7d \
  --scope '{"amc":{"view":["product:acme/*"],"actions":["read","summaries.read"],"deny":["tag:private"]}}'
```

**The framework never interprets it.** It guarantees exactly two things:

- **Integrity.** The object is placed *inside the payload* — the same bytes `caps`, `exp` and
  `bind` live in — so it rides inside the schnorr-signed event content (v1) and inside the
  AES-GCM-sealed, schnorr-signed content (v2). A bearer who edits the scope to widen it, or
  strips it to fall back to a consumer's permissive default, breaks the signature and the
  ticket fails to verify. Scope is exactly as tamper-evident as `caps` — no separate
  mechanism, no second signature, nothing to keep in sync.
- **Shape.** `--scope` must parse as a **non-empty JSON object** within `$TK_SCOPE_MAX_BYTES`
  (default 4096, compacted). Anything else fails the *issue* loudly — nothing is signed,
  published or recorded — rather than persisting garbage a verifier would later have to guess
  at. The cap matters because the v2 payload is published to a relay.

The top-level key is the **consumer's** namespace (`"amc"` for Agentic Mission Control), which
keeps two consumers' claims from colliding in one ticket and lets a consumer ignore a scope
that is not addressed to it.

> **Pin the issuer.** `verify` establishes that a payload was signed by whoever `iss` names —
> **not** that `iss` is anyone you trust. A `d`-tag is not globally exclusive: anyone can
> publish their own kind-30777 event under the same `d` (or mint a fresh ticket outright),
> self-consistently signed with `iss` set to their own npub, and it verifies. This is a
> property of the whole payload, `caps` included, and predates `scope` — but a consumer that
> uses a ticket as a **login credential** must compare `vres.iss` against the npub(s) it
> actually accepts, or an attacker can hand themselves any caps and any scope they like.

`ticket.sh verify` surfaces it verbatim as a `scope` key in its verdict, and **only** when the
payload actually carries an object:

```
$ ticket.sh verify - --require-cap deck   # scope-less ticket (unchanged since day one)
{"ok":true,"tid":"t…","iss":"npub1…","exp":1765432100,"caps":["deck"]}

$ ticket.sh verify - --require-cap deck   # scoped ticket
{"ok":true,"tid":"t…","iss":"npub1…","exp":1765432100,"caps":["deck"],"scope":{"amc":{…}}}
```

**Compatibility, in both directions.** A ticket issued *without* `--scope` produces the same
payload, the same ledger row and the same verdict as before this feature existed — every
existing consumer keeps working untouched. A *new* scoped ticket presented to an *old*
`ticket.sh` verifies normally: the extra payload field is simply ignored, so nothing errors.

**That second direction is the one consumers must think about.** An old verifier cannot be
taught to see a field it predates, so it will report a scoped ticket as scope-less — and a
consumer whose default for "no scope" is permissive would then *widen* a deliberately narrow
ticket. This is inherent to any additive claim and cannot be fixed on the framework side
(making old code reject would require breaking `caps` validation, which fails the whole
ticket rather than degrading). It is instead a **consumer obligation**:

> A consumer that issues scoped tickets MUST record, at first successful verification, that a
> given `tid` is scoped, and MUST fail closed — not fall back to its permissive default — if a
> later verification of that same `tid` comes back without a scope.

(Agentic Mission Control does exactly this: it stamps a `scoped` flag into its session cookie
at login and resolves a scoped session whose ceiling is missing to `REVOKED`, never to full
view.)

That covers "the ceiling went missing *after* login". It cannot cover "the verifier was old at
login time", because the consumer has nothing to compare against. For that, ask:

```bash
ticket.sh features
# → {"ticketSh":1,"formats":["v1","v2"],"features":["scope"]}
```

A consumer that depends on `scope` should probe once at startup and refuse to run if `scope`
is absent from `features`. This works precisely because a **pre-scope `ticket.sh` has no
`features` subcommand**: it hits the usage line and exits non-zero, so the probe fails loudly
rather than returning a reassuring answer. `features` is append-only — entries are never
removed or repurposed — so membership is the only test a consumer needs.

A `--require-scope` *flag* on `verify` would have been the obvious alternative and is a trap:
`tk_verify`'s argument loop silently discards unrecognized `-*` options, so old code would
drop the flag and answer `ok:true` anyway — failing open, which is the exact failure the probe
exists to prevent. The probe is a subcommand for that reason.

### 3.2 v1 encoding + signature (legacy)

The ticket string is a **signed Nostr event** wrapping the payload, so verification reuses
the exact signing machinery the SDK already uses for publishing (no new crypto surface):

```
unicity-ticket:v1.<base64url( minified-JSON of the signed event )>
```

where the event is:

```json
{ "kind": 30777, "pubkey": "<issuer hex>", "created_at": <issue ts>,
  "tags": [["d", "<tid>"], ["expiration", "<exp>"]],
  "content": "<base64url(canonical payload JSON)>",
  "id": "<sha256 of NIP-01 serialization>", "sig": "<64-byte schnorr>" }
```

Built and verified by two new `sphere-helper.mjs` subcommands (§7.2). Both take their
secret-bearing input on **stdin** (or `--in-file <path>`), never argv (§8, local-exposure):
`ticket-sign --identity <identity.json>` (payload JSON on stdin) → signed-event JSON, and
`ticket-verify` (event JSON on stdin) → `{valid, pubkey, npub, payload}` (standard NIP-01 id
recompute + schnorr verify; `payload` only emitted when `valid:true`, the event
`kind == 30777`, **and** `event.pubkey == decode(payload.iss)` — a signature by any key
other than `iss`, or a non-30777 kind, is invalid).

**What the redeemer verifies, before any network send** (all fail-closed, loud):
1. prefix + version are known;
2. the event verifies (`ticket-verify`) and its `pubkey` equals the decoded `iss` npub
   (`_ar_npub_to_hex`, which fully validates the bech32 checksum);
3. `exp` is in the future; `caps`/`grantBack` are within `AGENT_CAPABILITIES`;
4. it prints `iss`/`issName`/`caps`/`grantBack`/`exp` so the human sees what mutual grant
   they are entering (skippable with `--yes` for the `setup.sh --ticket` path).

**Why sign at all** (the ticket already travels out-of-band): the signature makes the
ticket **tamper-evident** — a party that can inject text into the paste channel cannot
escalate `caps`/`grantBack`, redirect `relays`, or swap `iss` on a legitimate ticket
without breaking the sig; and nobody can mint a ticket *naming someone else's npub as
issuer*. What it cannot do is stop wholesale replacement with an attacker's own ticket —
that residual risk is inherent to any out-of-band invite (same as today's invite blurb)
and is called out in §8.

Size: ~700–800 chars, one line — fine for chat/email/QR.

---

## 4. State

### 4.1 Issuer: `<coord_root>/tickets.json`

Lives beside the other coordination stores (`coord_root()` from `remote-coord.sh`), written
exclusively through `_rc_write` (mandatory flock, fail-closed on lock timeout — the #21/#23
posture verbatim).

```json
{ "tickets": [ {
    "tid": "t8f3a1c92be07",
    "secretHash": "<sha256 hex of the secret — NEVER the secret itself>",
    "caps": ["self-directed","consult","claim-area"],
    "grantBack": ["self-directed","consult","claim-area"],
    "bind": "",
    "label": "dev-2 peer",
    "exp": "2026-08-15T10:00:00Z",
    "status": "pending",
    "createdAt": "2026-08-14T10:00:00Z",
    "redeemedBy": null,
    "redeemedAt": "",
    "grantSentAt": ""
} ] }
```

`status ∈ pending | redeemed | expired | revoked | error`. `redeemedBy` becomes
`{hex, npub, name}` on consumption. Reaping: `ticket.sh reap` (called from the same places
`rc_reap` runs) marks past-`exp` pending tickets `expired` and deletes terminal records
older than `RC_REAP_DAYS`.

**One-time consumption semantics (atomic, concurrent-redeem safe).** Consumption is a
single `_rc_write` whose jq filter transitions **only** `pending → redeemed`:

```
.tickets |= map(if .tid==$tid and .status=="pending" and .exp > $now
                then (.status="redeemed" | .redeemedBy=$who | .redeemedAt=$now)
                else . end)
```

then the caller **re-reads** the record and proceeds iff `.redeemedBy.hex == <sender hex>`.
Because `_rc_write` serializes under flock, two concurrent redeems cannot both observe
`pending`; exactly one wins, the loser sees the winner's hex on re-read and is denied. A
flock timeout fails the redeem (nothing authorized, event not marked seen → retried).

### 4.2 Redeemer: `<coord_root>/redemptions.json`

```json
{ "redemptions": [ {
    "tid": "t8f3a1c92be07",
    "issuerNpub": "npub1abc…", "issuerHex": "<decoded>", "issuerName": "<coordinator-nametag>",
    "grantBack": ["self-directed","consult","claim-area"],
    "expectCaps": ["self-directed","consult","claim-area"],
    "exp": "2026-08-15T10:00:00Z",
    "status": "sent",
    "sentAt": "…", "grantedAt": ""
} ] }
```

`status ∈ sent | granted | denied | timeout`. Written at redeem-send time; this local,
signed-ticket-derived record — not the wire — is the source of the caps we grant the
issuer, and the allow-list the daemon-path grant handler matches against (§6.3).

### 4.3 Redeem-attempt rate-limit ledger: `<coord_root>/ticket-attempts.json`

`{ "attempts": [ {hex, tid, ok, at} ] }`, capped to the newest 500 entries on write.
Enforcement (issuer side, before any secret comparison): max **5 failed** attempts per
sender hex per hour and **50 failed** per day globally; beyond either, the redeem is
dropped with a single `WARN` log line (no `ticket.deny` — don't give an abuser an oracle
or an amplification channel). Mirrors the `STASH_PER_HEX_MAX`/`STASH_TOTAL_MAX` bounded-
disk reasoning in `classify-inbound.sh`.

---

## 5. Wire protocol

Three new envelope kinds, in the standard peer envelope shape produced by `rc_envelope`
(`{a2a, kind, id, lamport, from, fromNpub, sentAt, payload}`), carried as NIP-17 encrypted
DMs via `rc_emit` → `sphere-helper.mjs send-dm`. **Identity on ingest is always the
transport-level sender pubkey** — the hex the daemon writes as `.from` after gift-wrap
unwrap — never `fromNpub` (which is display/hint only, exactly as everywhere else in
`classify-inbound.sh`).

### 5.1 `ticket.redeem` (redeemer → issuer)

```json
{ "kind": "ticket.redeem", "payload": {
    "tid": "t8f3a1c92be07",
    "secret": "<the bearer secret from the ticket>",
    "npub": "<redeemer npub — hint; identity is the transport sender hex>",
    "name": "<redeemer nametag>"
} }
```

Sent signed by the redeemer's nsec (that's what `send-dm --identity` does), so the issuer
authorizes exactly the key that proved control of itself by sending the message — the
redeem is **bound to the redeemer's identity by the transport**, not by any payload claim.

### 5.2 `ticket.grant` (issuer → redeemer)

```json
{ "kind": "ticket.grant", "payload": {
    "tid": "t8f3a1c92be07",
    "status": "granted",
    "caps": ["…granted to the redeemer…"],
    "grantBack": ["…echo of what the issuer asks back…"],
    "issuerName": "<coordinator-nametag>"
} }
```

`caps`/`grantBack` here are **informational echoes** for the log; the redeemer acts only on
its locally-stored `redemptions.json` values (defense against a compromised-issuer or
mangled payload asking for wider caps than the signed ticket carried).

### 5.3 `ticket.deny` (issuer → redeemer, fail-loud)

```json
{ "kind": "ticket.deny", "payload": { "tid": "…", "reason": "expired|already-redeemed|bind-mismatch|unknown-ticket|invalid" } }
```

Sent for honest failures so the redeemer's single command fails loudly with a real reason
instead of a silent timeout (#20/#21 philosophy). NOT sent once a sender hex is over the
rate limit (§4.3).

**Idempotent re-redeem:** if a `ticket.redeem` arrives for an `already-redeemed` ticket
**and** the sender hex equals `redeemedBy.hex`, the issuer does not deny — it re-sends
`ticket.grant` (the previous grant may have been lost in flight; authorize is already
idempotent). Any *other* hex gets `ticket.deny already-redeemed`.

### 5.4 Capability map — deliberately NOT in `rc_verb_cap`

`ticket.redeem`/`ticket.grant`/`ticket.deny` are **not** added to `rc_verb_cap()`: those
verbs must work from senders who are by definition not yet authorized, and their gate is
the ticket secret / the pending-redemption record — not a registry capability. Keeping them
out of the verb map means `is_coord_verb()` stays false for them (no deferred-stash path —
they have their own handling), and the existing authorized-sender verb routing is
untouched.

---

## 6. The mutual-auth handshake, step by step

```
 ISSUER (A)                                        REDEEMER (B)
 ─────────                                         ────────────
 1. ticket.sh issue …
    → mint secret, tid=sha256(secret)[:12]
    → sphere-helper ticket-sign (nsec_A)
    → tickets.json += {tid, secretHash, caps,
      grantBack, exp, status:pending}
    → print unicity-ticket:v1.…
                     ── out-of-band paste ──────►
                                                   2. setup.sh --ticket … / ticket.sh redeem …
                                                      → ticket-verify: sig valid ∧ pubkey==iss
                                                      → exp in future, caps valid, show summary
                                                      → agent-registry upsert-peer (iss cached)
                                                      → redemptions.json += {tid, issuerHex,
                                                        grantBack, status:sent}
                                                   3. rc_emit ticket.redeem {tid, secret} → A
                                                      (SIF egress; signed NIP-17 DM)
 4. daemon → on-dm.sh → classify-inbound
    ticket.redeem case (any sender status):
    a. SIF inbound (flag ⇒ quarantine, stop)
    b. rate-limit check on sender hex (§4.3)
    c. sha256(payload.secret) == secretHash?
       exp unexpired? bind matches sender hex
       (when set)?             — any no ⇒ ticket.deny + attempt log
    d. ATOMIC consume: pending→redeemed
       {hex,npub,name}; re-read to confirm we
       won (§4.1)              — lost race ⇒ ticket.deny already-redeemed
    e. agent-registry.sh authorize <sender hex>
       <caps> --note "ticket <tid>: <label>"
       → deferred-replay #14 fires: any earlier
         coordination envelopes from B re-enter
         the queues through the full cap+SIF gate
    f. rc_emit ticket.grant → B (SIF egress);
       stamp grantSentAt (send-fail ⇒ status
       stays redeemed, grantSentAt empty —
       surfaced on the Stop gate; B's re-redeem
       triggers the idempotent re-grant §5.3)
                     ◄── ticket.grant ────────────
                                                   5. B receives the grant — two paths, both
                                                      converging on redemptions.json:
                                                      • CLI path (works pre-daemon): redeem
                                                        polls sphere-helper check-messages
                                                        (~5s interval, 120s timeout) for a
                                                        gift-wrap from issuerHex with kind
                                                        ticket.grant + matching tid
                                                      • daemon path (late grant): classify-
                                                        inbound ticket.grant case matches a
                                                        redemptions.json entry {tid,
                                                        issuerHex==sender, status:sent}
                                                   6. verify: transport sender hex ==
                                                      redemptions.tid.issuerHex (else IGNORE,
                                                      log loud)
                                                   7. agent-registry.sh authorize <issuerHex>
                                                      <stored grantBack> --note "ticket <tid>"
                                                      → redemptions.tid.status = granted
                                                   8. print MUTUAL-AUTH OK summary
```

**End state:**
- A's registry: B's hex `authorized`, caps = ticket `caps`, note names the ticket; B's
  stashed pre-auth envelopes (if any) replayed through the full gate.
- B's registry: A's hex `authorized`, caps = ticket `grantBack`.
- A's `tickets.json`: the ticket `redeemed` by B, grant timestamped.
- B's `redemptions.json`: `granted`.
- B can immediately `/consult-coordinator <issName>` (nametag resolves from the registry
  cache seeded in step 2) and A's replies route straight through.

Every failure branch is loud: sig/exp/caps fail at step 2 abort before any network call;
deny reasons print at B; a lost grant is visible on A's Stop gate (`grantSentAt` empty) and
self-heals on B's re-redeem.

---

## 7. Component changes

### 7.1 NEW `claude_conf/hooks/ticket.sh` — the ticket engine (~400 lines)

Dual-use module in the house style (guarded CLI; sourcing only defines functions), sourcing
`agent-registry.sh` + `remote-coord.sh` for `_rc_write`, `coord_root`, `rc_envelope`,
`rc_emit`, `rc_self_npub`, `_ar_npub_to_hex`, `_ar_validate_caps`, `registry` calls.

```
ticket.sh issue   [--caps csv] [--grant-back csv] [--ttl 15m] [--bind npub]
                  [--name|--label L] [--relay url]        → prints the ticket string
ticket.sh list    [status]                                → issuer ledger (tickets.json)
ticket.sh revoke  <tid>                                   → pending → revoked (fail-closed on absent)
ticket.sh redeem  <ticket-string> [--yes] [--timeout 120] → the whole redeemer flow §6 steps 2–8
ticket.sh ingest-redeem <event-json|->                    → issuer steps 4a–4f (called by classify-inbound)
ticket.sh ingest-grant  <event-json|->                    → redeemer daemon-path steps 5–7
ticket.sh ingest-deny   <event-json|->                    → mark redemption denied + loud log
ticket.sh reap                                            → expire/prune (called beside rc_reap)
ticket.sh self-test                                       → local sign→verify round-trip
```

Defaults: `--caps` = the minimal coordination set (`consult,claim-area`) — least privilege;
widen explicitly (e.g. add `task-bid`) when a ticket needs more. `--grant-back` defaults to
`--caps`. Caps are validated via `_ar_validate_caps`; including
a cap from `AGENT_CAPS_DESTRUCTIVE` prints a red warning at issue time (grant still only
*permits asking* — destructive execution keeps its owner-confirmation, unchanged).

### 7.2 `lib/sphere-helper.mjs` — two subcommands

- `ticket-sign --identity <path>` (payload JSON on **stdin** / `--in-file`) → builds the
  kind-30777 event with `content = base64url(payload)`, signs with the identity key (same
  `keyManagerFromIdentity` path used by `send-dm`), prints the signed event JSON.
- `ticket-verify` (event JSON on **stdin** / `--in-file`) → recomputes the NIP-01 id,
  asserts `kind == 30777`, schnorr-verifies `sig` against `event.pubkey`, decodes
  `content`, checks `event.pubkey == decode(payload.iss)`; prints `{valid, pubkey, npub,
  payload}`; exit 1 on any failure.
- `send-dm <npub> --identity <path>` reads the DM body from **stdin** / `--body-file` (the
  body may carry a ticket secret) — never argv.

No relay interaction in either; pure local crypto through `@unicitylabs/nostr-js-sdk`.

### 7.3 `claude_conf/hooks/classify-inbound.sh` — two routing cases

Inside the per-message loop, **after** the owner short-circuit and **before** the
registry-status `case` (ticket verbs are status-independent; an already-authorized sender
redeeming a second ticket is legal and idempotent):

```bash
if [ "$ENV_KIND" = "ticket.redeem" ] || [ "$ENV_KIND" = "ticket.grant" ] || [ "$ENV_KIND" = "ticket.deny" ]; then
  # SIF first (capture-then-parse, fail-closed on flag), then hand to the engine.
  # ticket.sh does ALL validation (secret hash, atomic consume, bind, rate limit,
  # matching pending redemption) and any authorize/grant-back sends.
  … SIF check as in the existing peer-verb branch …
  [ "$SIF_Q" = "1" ] && quarantine_message … || bash "$HOOK_DIR/ticket.sh" "ingest-${ENV_KIND#ticket.}" "$MSG"
  AUTHZJSON="$(jq -nc --arg kind "$ENV_KIND" '{role:"agent", ticketVerb:$kind, classified:true}')"
fi
```

The engine receives the queued-message wrapper (so it reads the transport `.from` hex
itself) and never trusts payload identity fields. Ordering note: this branch must also run
for senders that are `pending`/`unknown` — which is precisely why it sits before the
status switch.

### 7.4 `setup.sh --ticket <t>` — true one-command onboarding

- New flag parsed beside `--dry-run`. When present:
  - **Phase 3b replacement:** decode + `ticket-verify` the ticket up front; pre-record the
    issuer as the coordinator peer (`agent-registry.sh upsert-peer --npub <iss> --name
    <issName>`) and default `RELAY_URL` to `relays[0]` — no coordinator prompts.
  - **New Phase 9.7 (after the transport preflight passes):** run
    `bash "$CLAUDE_DIR/hooks/ticket.sh" redeem "$TICKET" --yes` — the redeem does its own
    `check-messages` polling, so it works **before the daemon is started**. On success the
    summary block prints `MUTUAL AUTH OK with <issName> (<iss>)`; on failure setup exits
    non-zero with the deny/timeout reason (framework stays installed; re-run
    `ticket.sh redeem` after fixing).
- End-to-end peer experience: `git clone … && ./setup.sh <project> --ticket '<t>'`, then
  start the daemon. One command past the clone; nothing to copy back to the issuer.

### 7.5 `claude_conf/hooks/check-diagnostics.sh` — Stop-gate surface (small)

Surface (a) issuer tickets in `status:redeemed` with empty `grantSentAt` (grant send
failed — nudge to re-run or wait for the peer's re-redeem) and (b) redeemer redemptions in
`status:sent` older than 10 minutes (grant never arrived — check the daemon/relay). Both
are one-line jq reads of the two stores.

### 7.6 Skills

- `claude_conf/skills/issue-ticket/SKILL.md` — wraps `ticket.sh issue`, explains cap
  choice + TTL + bind, reminds the operator the printed string is a bearer credential
  (send over a private channel; `revoke <tid>` if it leaks).
- `claude_conf/skills/redeem-ticket/SKILL.md` — wraps `ticket.sh redeem` for the
  post-setup case; verifies the daemon or falls back to the built-in poll; ends by
  suggesting `/consult-coordinator <issName> …`.

### 7.7 Untouched on purpose

`onboard-teammate.sh` keeps working as the manual/npub-first path (its invite text gains a
one-line pointer to tickets). `remote-coord.sh`'s verb map, `team-coord.sh`, the daemon,
and `on-dm.sh` need **no changes** — tickets ride the existing DM ingest path end to end.

---

## 8. Security analysis

The ticket is a **bearer token**: whoever presents the secret first gets authorized.
Everything below either narrows that window or bounds the damage.

**Threat: stolen/leaked ticket.**
- 256-bit secret from `/dev/urandom`; the issuer stores only `sha256(secret)` — a read of
  `tickets.json` (or a backup) yields nothing redeemable.
- Single-use with **atomic flock-serialized consumption** (§4.1): a thief and the intended
  peer cannot both win; the loser's deny (`already-redeemed`, naming no one) plus the
  issuer's ledger (`redeemedBy` hex) make a hijack immediately visible.
- Short default TTL (24h) and `ticket.sh revoke <tid>` for known leaks.
- `--bind <npub>` closes the bearer window entirely when the peer's npub is already known
  (checked against the transport-authenticated sender hex — unspoofable) — at the cost of
  one extra out-of-band datum; recommend it for high-value caps.
- Blast radius of a successful theft = the ticket's caps, which default to the
  **non-destructive** coordination set; `AGENT_CAPS_DESTRUCTIVE` execution still requires
  owner confirmation regardless of any grant, and `deny <hex>` reverses the authorization
  in one command.

**Threat: replay.**
- The redeem envelope is dedup'd by event id at every layer (daemon seen-set,
  `rc_seen_*`-style dedup in the engine), and the nonce is consumed — a replayed redeem
  hits `already-redeemed`. The only "replay" that does anything is the **same** hex
  re-redeeming, which deliberately re-sends the grant (idempotent recovery, §5.3).
- The grant is bound to `tid` + issuer hex + a `status:sent` local record; replaying an
  old grant is a no-op once `granted`.

**Threat: malicious redeemer.**
- Gets exactly the pre-decided caps — the same ones the owner would have typed into
  `onboard-teammate.sh` — and its identity is pinned to the key that signed the redeem
  DM. Impersonation-by-name is irrelevant (names are never boundaries here).
- Its subsequent traffic passes the unchanged default-deny + SIF + per-verb cap gates;
  deferred-replay re-runs the full gate per envelope (already the #14 posture).
- A malicious *payload* can't widen anything: the issuer takes caps from **its own
  tickets.json**, the redeemer takes grant-back caps from **its own redemptions.json**;
  wire fields are hints/echoes only.

**Threat: ticket forgery / tampering.**
- Schnorr signature over the canonical payload, verified against the decoded `iss` before
  any send: no cap escalation, relay redirection, or issuer substitution on a legitimate
  ticket; no minting tickets in someone else's name. Residual: an attacker who fully
  controls the paste channel can substitute their *own* ticket (their npub, their sig) —
  inherent to out-of-band invites; the redeem-time summary printing `iss`/`issName` is the
  human checkpoint, and `--bind`-style pre-knowledge on the *peer's* side (verifying the
  expected coordinator name/npub) is the operational advice in the skill text.

**Threat: DoS / brute force.**
- Online guessing of a 256-bit secret is not a realistic threat, but the rate limiter
  (§4.3: 5 failed/hex/hour, 50 failed/day global, silent-drop past limits) keeps a
  flooder from filling logs/disk or using `ticket.deny` as an amplification oracle.
- All stores are bounded (attempt ledger capped at 500; tickets/redemptions reaped on the
  existing `RC_REAP_DAYS` cycle); no per-message file creation for invalid redeems.
- A flood of *valid-looking* first-contact envelopes still lands in the existing bounded
  deferred stash — unchanged.

**Threat: local secret exposure via process arguments.**
- The ticket secret (and any envelope that carries it, e.g. `ticket.redeem`) is **never
  passed on a command line** — `ps` / `/proc/<pid>/cmdline` is world-readable, so an argv
  secret leaks to any local user for the command's lifetime. Instead:
  `sphere-helper.mjs ticket-sign` / `ticket-verify` read the payload/event from **stdin**
  (or a `--in-file <path>` 0600 file); `send-dm` reads the DM body from **stdin** /
  `--body-file`; `rc_emit` and the team-coord send path pipe the envelope in via stdin;
  `setup.sh --ticket` hands the ticket to `ticket.sh` through a `mktemp` **0600** file
  (`umask 077`, `trap … EXIT` cleanup), and `ticket.sh redeem --ticket-file` reads it there.
  Only non-secret arguments (`--identity <path>`, a recipient npub) remain on argv. Covered
  by a regression test that shims `node`, records every child argv, and asserts neither the
  base64 event content nor a sentinel secret ever appears (§9.1).

**Threat: hostile relay.**
- Content is NIP-17 encrypted end-to-end; the relay sees gift wraps only. A relay can
  *drop* messages — which surfaces as a loud redeem timeout / Stop-gate nudge, never a
  silent half-authorized state (each side's grant is recorded only on its own verified
  step).

**v2-specific threats (the published kind-30777 event).**
- *Relay reads the authorization:* content is AES-256-GCM under a secret-derived HKDF key —
  the relay (or anyone querying) learns only issuer pubkey + SHA-256(secret) + expiry tag.
  Publishing the hash is equivalent to v1's hash-at-rest posture: with ≈256 bits of secret
  entropy it is not invertible or guessable, and knowing it only lets you *fetch* the
  (opaque) event, never redeem — redemption still requires presenting the secret itself to
  the issuer, whose ledger does the one-time consume.
- *Event forgery / clutter under the same `d`:* addressable-event addresses are
  (kind, pubkey, d) — nobody can replace the issuer's event. An attacker can publish their
  own event with the same `d` after observing it, including a verbatim copy of the
  ciphertext re-signed under their key: sig+decrypt pass, but `payload.iss == event.pubkey`
  fails (the iss binding is inside the GCM-authenticated ciphertext, unmodifiable without
  the key). The redeemer verifies every candidate and proceeds only with the one that passes
  the full chain; hostile clutter can at worst emit a specific rejection reason.
- *Relay drops/loses the event:* issue fails loudly unless the relay ACKed the publish; a
  later fetch miss fails the redeem closed with actionable causes. No silent states.
- *Hash pre-image linking:* the `d` value is derived with plain SHA-256 (no salt) — fine,
  because the pre-image is itself a 256-bit-entropy secret, never a low-entropy value.

**Fail-closed inventory** (the #21/#23 "fail loud, never silent" rule): unknown version,
bad sig, sig-key ≠ iss, expired, unknown tid, hash mismatch, bind mismatch, lost consume
race, flock timeout, jq failure, SIF flag (either direction), grant from a hex ≠ pinned
issuerHex, grant with no matching `sent` redemption → in every case **nothing is
authorized**, the event is not marked seen where a retry is meaningful, and a human-visible
reason is emitted (deny message, WARN log, or Stop-gate line).

---

## 9. Test plan

### 9.1 Hermetic unit/E2E — NEW `test/onboarding-ticket.test.sh`

Same harness style as `test/team-coordination.test.sh` (temp sandbox, real hooks copied in,
`TEAM_DRY_RUN` where sends aren't under test, messages crafted exactly as the daemon
delivers them and fed through `classify-inbound.sh`):

1. **Happy path:** issue on identity A → craft the redeem DM as from identity B's hex →
   classify-inbound → assert: B authorized in A's registry with the ticket caps; ticket
   `redeemed` with B's hex; a `ticket.grant` egress produced (dry-run capture). Feed the
   grant into B's sandbox → assert A authorized in B's registry with `grantBack`.
2. **Signature:** flip one byte of the payload → `ticket-verify` fails → redeem aborts
   before any send. Sign with a non-iss key → same.
3. **Expiry:** issue `--ttl 1s`, sleep, redeem → `ticket.deny expired`, nothing authorized.
4. **Double-redeem race:** fire two concurrent `ingest-redeem` for the same ticket from
   different hexes (background jobs) → exactly one `redeemed`/authorized, one
   `already-redeemed` deny, registry has exactly one new entry.
5. **Idempotent re-redeem:** same hex redeems again → grant re-sent, no state change.
6. **Bind mismatch:** `--bind npub_C`, redeem from B → deny, nothing authorized.
7. **Rate limit:** 6 bad-secret redeems from one hex → 5 denies then silent drop;
   attempts ledger bounded.
8. **Grant-path hardening:** grant from wrong hex → ignored loudly; grant with widened
   caps in payload → registry gets the locally-stored caps only.
9. **Deferred-replay integration:** stash a `consult.request` from B pre-redeem → redeem
   → assert it re-entered the consult queue through the cap+SIF gate.
10. **Revoke + reap:** revoked and expired tickets deny; reap prunes terminal records.

### 9.2 Live loopback (developer machine, real relay)

Two identities on one host, both daemons `--live` against
`wss://nostr-relay.testnet.unicity.network`: issue on A, `ticket.sh redeem` on B, assert
mutual `authorized` entries and a `/consult-coordinator` → `/coordinator-advise` round-trip.

### 9.3 Life test — fresh peer in an isolated Docker container

The acceptance test for the whole feature, against the **real testnet relay** and our
**live coordinator**:

```
1. On the live coordinator:  ticket.sh issue --ttl 2h --name docker-life-test   → <T>
2. docker run --rm -it node:22-bookworm bash   (clean container, no volumes)
3. In-container: apt-get install -y jq git;
   git clone https://github.com/vrogojin/claude-unicity-setup.git && cd claude-unicity-setup
   git init /tmp/proj-stub && <seed a minimal git project dir>
   ./setup.sh /tmp/proj-stub --ticket '<T>'       # answers only the nametag/owner prompts
4. Assert in-container: setup ends "Setup Complete" + "MUTUAL AUTH OK";
   agent-registry.json has the coordinator hex authorized with the grant-back caps.
5. Assert on the coordinator: tickets.json shows the ticket redeemed by the container's
   hex; registry shows it authorized; Stop gate shows nothing pending.
6. In-container: start the daemon (nohup … --live), run
   /consult-coordinator <coord-name> "life-test ping" → on the coordinator,
   /coordinator-advise answers → in-container the advisory lands on the consult thread.
7. Re-run step 3's redeem with the SAME ticket from a second container → deny
   already-redeemed; coordinator registry unchanged.
8. Cleanup: coordinator runs agent-registry.sh deny <container-hex> + ticket reap.
```

Pass = mutual authorization with zero manual coordinator-side steps between issuing the
ticket and answering the consult.

---

## 10. Implementation order

1. `sphere-helper.mjs` `ticket-sign`/`ticket-verify` (+ self-test).
2. `ticket.sh` engine: stores, issue/list/revoke/reap, ingest-redeem with atomic consume,
   redeem CLI with built-in grant poll, ingest-grant/deny.
3. `classify-inbound.sh` routing cases.
4. Hermetic test suite (§9.1) — green before any live traffic.
5. `setup.sh --ticket`, Stop-gate lines, the two skills, doc updates
   (`TEAMMATE-ONBOARDING.md`, `agent-coordination.md`).
6. Live loopback, then the Docker life test (§9.3).
