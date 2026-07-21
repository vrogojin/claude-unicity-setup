# R1 — Existing Setup Audit: `/home/vrogojin/claude_unicity_setup`

Ground-truth verification of the Nostr agent-messaging layer. All file:line refs verified against the working tree. SDK versions confirmed installed: **`@unicitylabs/sphere-sdk@0.4.3`**, **`@unicitylabs/nostr-js-sdk@0.3.3`**.

---

## 1. End-to-end data flow

### 1a. Inbound DM (relay → Claude's context)

```
Nostr relay (wss://nostr-relay.testnet.unicity.network)
  │  kind 1059 gift-wrap, #p = my x-only pubkey
  ▼
lib/sphere-helper.mjs  checkMessages()            [:215–299]
  • createNostrClient() builds NostrKeyManager from identity.json + client.connect(...relays)  [:73–95, :226]
  • Filter{ kinds:[GIFT_WRAP(1059)], '#p':[myPubkeyHex], since }  [:235–239]
  • client.subscribe(dmFilter, cb)                 [:241]
  • cb: client.unwrapPrivateMessage(event) → { senderPubkey, content, ... }  [:243]
  • push { type:'dm', from:senderPubkey, body:content, priority:(sender===owner), read:false }  [:246–253]
  • 5-SECOND collection window (setTimeout)        [:287]
  • output({ messages, polled_at })  → stdout JSON  [:293]
  ▼
lib/sphere-daemon.mjs   poll()                     [:176–198]
  • execFileSync('node', helper 'check-messages' --since <lastPollTime/1000>)  [:118–128]
  • for each msg: msg.type==='dm' → runHook(hooks.on_dm, msg)  [:192–193]
  • runHook spawns bash, writes JSON.stringify(msg) to hook stdin  [:97–103]
  • Poll loop: setInterval(poll, 60_000)  (default interval 60s)  [:204, :261]
  ▼
.claude/hooks/on-dm.sh                             [reads stdin msg JSON]
  • SENDER = .pubkey // .from  [:19] ; BODY = .content // .body  [:20]
  • recompute IS_PRIORITY: SENDER == owner_npub  [:36, :43]   ← see BUG-1
  • jq-build entry, APPEND to $STATE_DIR/agent-messages.json  [:48–80]
  • notify.sh → desktop / ntfy push of ${BODY:0:100}  [:83–92]
  ▼
/tmp/claude/<sha1(repo-root)[:12]>/agent-messages.json     (state-dir.sh scheme)
  ▼
Stop hook  .claude/hooks/check-diagnostics.sh      [:96–104]
  • if .priority_count > 0 → BLOCK Stop, tell agent to run /check-messages
  ▼
Skill  .claude/skills/check-messages/SKILL.md      [HUMAN-invoked]
  • Step 1: read agent-messages.json  • Step 3: render "message body" verbatim into model context
  • Step 4: mark read (unread=false, counts=0)
```

**Fallback path (no daemon):** `.claude/hooks/agent-comms-check.sh` is an **async PostToolUse hook on `Bash`** (settings.json:73–83). After any Bash call, 10-min cooldown (`:33`), it runs the same `check-messages` helper and **merges** results into the same state file (`:82–89`), then notifies.

### 1b. Inbound group message

Identical shape, diverging at the helper: `Filter{ kinds:[9], '#h':[groupId], since }` (`sphere-helper.mjs:265–269`), skips own pubkey (`:273`), pushes `type:'group'` (`:275–282`) → daemon routes to `hooks.on_group_message` (`:194–195`) → `on-group-message.sh` filters own npub (`:30–32`), extracts `#h` group id (`:22`), appends to the same state file, notifies. Same Stop-gate + `/check-messages` skill terminus.

**Nothing autonomous ever *replies*.** Every path terminates by writing a state file + desktop/push notification and waiting for a human to invoke `/check-messages`. There is no responder.

---

## 2. Capability matrix (WORKS / STUB / MISSING)

| Capability | Status | Evidence |
|---|---|---|
| Create identity (BIP-39 → secp256k1 → npub/nsec) | **WORKS** | `sphere-helper.mjs:108–136` (generateMnemonic, deriveKeyAtPath, encodeBech32) |
| Send NIP-17 DM by npub | **WORKS** | `:188–213`, `client.sendPrivateMessage(hex, msg)` `:206` |
| Poll inbound DMs (gift-wrap 1059) | **WORKS** | `:235–258`, 5 s window `:287` |
| Poll inbound group msgs (kind 9, `#h`) | **WORKS** | `:265–283` |
| Daemon poll→hook dispatch | **WORKS (polling, not push)** | `sphere-daemon.mjs:176–204`; 60 s interval `:261` — contradicts CLAUDE.md "real-time push" |
| Write inbound msg to state + notify | **WORKS** | `on-dm.sh:48–92`, `on-group-message.sh:53–103` |
| Stop-gate on unread priority | **WORKS** | `check-diagnostics.sh:96–104` |
| **resolve-nametag → npub** | **STUB** | `:138–153` — hashes, then `output({…, npub: null})` `:152`. Never subscribes. SDK **does** support it: `nostr-js-sdk` ships `NametagBinding.createNametagToPubkeyFilter()` + `parseAddressFromEvent()`, and `NostrClient.sendPrivateMessageToNametag()` (`NostrClient.d.ts:283`) — all unused. |
| **join-group (real NIP-29)** | **STUB** | `:155–186` — comment "output the group config without actual relay interaction" `:170`; emits `status:'configured'` `:179`, publishes **no** kind-9021 join. setup.sh then falls back to a placeholder id string `unicity-dev-agents-<net>` (`setup.sh:620–623`). |
| **Authorization firewall (sender allowlist / approve-new-contact)** | **MISSING** | no allowlist anywhere; `checkMessages` accepts every sender `:241`; `on-dm.sh` surfaces all `:80`. `daemon.json.subscriptions.dm_contacts` is written (`setup.sh:688`) but **never read** by the helper. |
| **Semantic / injection firewall on inbound** | **MISSING** | zero references to semanticd or any content scan; body flows raw (see §3). |
| **Autonomous responder on inbound** | **MISSING** | daemon only writes state + notifies (`sphere-daemon.mjs:191–197`); no `claude -p` / task enqueue. |
| **Concierge ↔ this-setup bridge** | **MISSING** | separate Nostr worlds; no shared config. |
| Real-time push transport | **MISSING** | daemon is `setInterval` polling only. |

### Correctness bugs found in the "WORKS" paths
- **BUG-1 (owner priority broken in daemon path):** `on-dm.sh:36,43` and `on-group-message.sh:47` compare the **hex** sender (`msg.from`, a 64-char hex pubkey) against `owner_npub` (a **bech32 `npub1…`** string from config). They never match, so **owner DMs via the daemon are never flagged priority** and never trip the Stop gate. The helper computes `priority` correctly (`sphere-helper.mjs:252`, hex-vs-hex via `npubToHex`), but the hooks **discard `msg.priority` and recompute** it wrong. (The async fallback `agent-comms-check.sh` preserves `msg.priority` `:87`, so priority works only on the no-daemon path.)
- **BUG-2 (unreliable timestamps):** `checkMessages` reads `unwrapped.created_at` (`:250`), but `PrivateMessage` exposes `timestamp` (unix s), **not** `created_at` (`nostr-js-sdk .../messaging/types.d.ts`). It falls back to `event.created_at` — the **gift-wrap** timestamp, which NIP-17 deliberately randomizes (±~2 days). DM timestamps are therefore wrong.
- **BUG-3 (no dedup):** both the daemon (`since=lastPollTime`) and `agent-comms-check.sh` (`since=now-600`, `:59`) use overlapping windows and **append** without an id check (`agent-comms-check.sh:82–89`; `on-dm.sh:72–80`). The same event re-surfaces every poll; `PrivateMessage.eventId` exists but is unused.
- **BUG-4 (dead subscription filter):** `daemon.json.subscriptions.dm_contacts` implies a contact filter but the helper subscribes to **all** gift-wraps to my pubkey (`:236`), ignoring it.

---

## 3. Injection surface — where untrusted text is first trusted

**Untrusted attacker-controlled bytes = the DM/group `content`.** Its trust journey, with the sanitization at each hop:

| Hop | Location | Sanitization |
|---|---|---|
| unwrap → JS object | `sphere-helper.mjs:249` `body: unwrapped.content` | **none** |
| JSON to hook stdin | `sphere-daemon.mjs:102` | none (JSON-encoded — safe transport only) |
| hook → state file | `on-dm.sh:20,48–80` via `jq --arg` | **shell-injection-safe** (jq arg binding), but **content-neutral** — no semantic check |
| desktop/push notify | `on-dm.sh:88–91` `${BODY:0:100}` → `notify.sh` | truncation only; not model-facing |
| **state → model context** | **`skills/check-messages/SKILL.md` step 3** — renders "`message body`" verbatim into Claude's context | **NONE** |

**The first and only point where attacker text becomes *trusted* (enters the reasoning context) is the `/check-messages` skill render step.** There is no content inspection anywhere on the path — classic **indirect prompt injection**: any Nostr pubkey can gift-wrap a DM to the agent's key, and its full body lands unfiltered in the model context the next time a human (or an autonomous responder, once one exists) reads the inbox. The `jq --arg` usage protects the *shell/state file* from breakage but does nothing about *semantic* payloads.

---

## 4. Identity, config, gitignore, second-machine provisioning

**Identity creation** (`setup.sh` Phase 2, `:363–468`): calls `sphere-helper create-identity` → writes `.claude/agent/identity.json` `{created_at, mnemonic, public_key, npub, nsec, derivation_path, nametag}`, `chmod 600` (`:399–400, :464–468`). Mnemonic printed once (`:406–412`). Fallback = manual npub/nsec import (`:414–434`).

**Config files** (Phase 8, `:639–702`):
- `config.json`: `{agent_nametag, owner_npub, owner_nametag, notification_url, group:{name,id,relays[]}, dep_tracking}` (`:644–668`). **No authorized-contacts field** — the natural home for an allowlist.
- `daemon.json`: `{relays[], subscriptions:{groups[], dm_contacts:[owner_npub]}, hooks:{on_dm, on_group_message}}` (`:677–692`).
- `settings.json.env.CLAUDE_NOTIFY_URL` patched (`:698–701`). `teammateMode:auto` + `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (`settings.json:3,6`) — the Claude-Code agent-teams feature is on but **not wired to Nostr**.

**Gitignored:** the whole `.claude/` dir is appended to target `.gitignore` (`:342–351`); `.mcp.json` + `.serena/` added by `deploy_serena_mcp` (`:164–174`). So `identity.json` (nsec/mnemonic) is never committed. Base `.gitignore` here = `node_modules/`, `.serena/`.

**Second-machine provisioning & addressing:** run `setup.sh <repo>` again → **new** mnemonic/npub (distinct identity). Cross-machine addressing is the weak spot:
- **By npub** works (send-dm), but requires manually exchanging the raw `npub1…` — because **`resolve-nametag` is a stub** (§2), human-readable `@nametag` addressing is non-functional despite the SDK supporting it.
- **Group membership is fictional:** `join-group` publishes nothing, so two machines only "share a group" by both carrying the same placeholder `group_id` string; there is no relay-side NIP-29 membership, no discovery, no roster. A relay that enforces NIP-29 would reject kind-9 posts to a group that was never created.

---

## 5. Integration seams for the three missing pieces

Precise attach points, minimal blast radius:

**A. Authorization firewall (drop/quarantine + approve-new-contact)**
- **Primary chokepoint:** the two subscription callbacks in `sphere-helper.mjs` — DM `checkMessages` cb (`:241–258`) and group cb (`:271–283`). Insert an allowlist check *before* `messages.push`. Source the allowlist from a **new `config.json` field** (e.g. `authorized_contacts:[npub…]`) — the schema is already assembled at `setup.sh:644–668`.
- **Defense-in-depth:** re-check in `on-dm.sh`/`on-group-message.sh` before the state write (`on-dm.sh:47`), so a bypassed helper can't leak.
- **Approve-new-contact flow:** route unknown senders to a `pending-contacts.json` quarantine + owner notify, plus a new skill/DM command (`/approve-contact <npub>`) that appends to `authorized_contacts`. Mirror it into `daemon.json.subscriptions.dm_contacts` (currently dead — BUG-4) so it becomes real.

**B. Semantic firewall (semanticd)**
- **Cleanest single call site:** immediately after `client.unwrapPrivateMessage` / group event receipt in `sphere-helper.mjs` (`:243–249` / `:275`) — POST `content` to semanticd (`/analyze`, batch-capable) via a **new isolated module `lib/semantic-firewall.mjs`** (keep the HTTP dep out of the hot path; fail-closed on error). Stamp each message with `{verdict, score}`.
- **Enforcement:** hard-drop/quarantine in `on-dm.sh`/`on-group-message.sh` before the state write, and again as a render-time guard in the `check-messages` skill (the actual trust boundary, §3). semanticd runs as the documented Docker sidecar (`docker run -p 8080:8080 semanticd/semanticd`); config the base URL alongside `relays` in `daemon.json`.

**C. Autonomous responder**
- **Seam:** `sphere-daemon.mjs` `runHook` dispatch (`:191–197`) + the `hooks` map in `daemon.json` (`setup.sh:688–691`). Add an `on_dm_respond` hook (or extend `on-dm.sh`) that — **only after** the authz+semantic verdicts pass — invokes a headless responder (`claude -p …` / enqueues a task) and sends the reply back via `sphere-helper send-dm`. Gate strictly: an autonomous responder reading unfiltered inbound text is exactly the injection amplifier §3 warns about, so it must sit **downstream** of A and B, never before them.

**Transport upgrade (orthogonal):** the 60 s `setInterval` (`sphere-daemon.mjs:204`) is the latency floor for "interactive consulting." `NostrClient.subscribe` is already an open live subscription — a long-lived daemon holding the subscription and dispatching in the callback (instead of connect→5 s→disconnect per poll, `sphere-helper.mjs:287,297`) converts this to real-time without new deps.