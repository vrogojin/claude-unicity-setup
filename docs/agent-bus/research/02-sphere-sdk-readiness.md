I have a complete picture. Writing the readiness assessment now.

The report below is my final deliverable.

---

# Latest sphere-sdk Readiness for the Universal DM Bus

**Scope:** Capability assessment of `@unicitylabs/sphere-sdk` + `@unicitylabs/nostr-js-sdk` as the transport engine for the "Unicity DM" universal secure bus (Claude agents ↔ Concierge ↔ humans).

## 0. Version state (installed vs. published)

| Package | Installed | npm `latest` | npm `dev` | Gap |
|---|---|---|---|---|
| `@unicitylabs/sphere-sdk` | **0.4.3** | **0.11.15** | 0.11.15-dev.1 | 7 minor versions behind |
| `@unicitylabs/nostr-js-sdk` | **0.3.3** | **0.6.0** | 0.5.0-dev.3 | 3 minor versions behind |
| `@unicitylabs/state-transition-sdk` | 1.6.1-rc.f37cb85 | (pinned dep) | — | pinned by sphere-sdk |

**Bottom line up front:** Even the *installed* 0.4.3 / 0.3.3 already exposes everything the DM bus needs — real-time subscriptions, NIP-17 DMs, a full high-level NIP-29 `GroupChatModule`, a `CommunicationsModule` with presence/read-tracking, and nametag resolve. **Almost every "CONFIRMED GAP" is un-implemented glue in `sphere-helper.mjs`, not an SDK limitation.** The current helper only uses the *low-level* `NostrClient` and never touches the high-level modules that already solve join-group, nametag resolve, presence, and real-time.

---

## 1. Feature-support matrix

| # | Capability | Supported? | Where (installed 0.4.3/0.3.3) | Gap type |
|---|---|---|---|---|
| a | **NIP-17 gift-wrap DMs** | ✅ Full | `NostrClient.sendPrivateMessage` / `sendPrivateMessageToNametag` / `unwrapPrivateMessage` | none — already used |
| b | **NIP-29 group create/join/post/subscribe** | ✅ Full (high-level) | `GroupChatModule` (`createGroup`, `joinGroup`, `leaveGroup`, `sendMessage`, `fetchMessages`, `onMessage`, `getMembers`, moderation) + `NIP29_KINDS` | **glue** — helper stubs it |
| c | **Nametag REGISTER + RESOLVE → npub** | ✅ Resolve now; register yes | `NostrClient.queryPubkeyByNametag` (resolve), `publishNametagBinding` (register) | **glue** — helper stub only hashes |
| d | **Real-time subscriptions / streaming** | ✅ Full | `NostrClient.subscribe(filter, listener)` — persistent WS, `onEvent` push, auto-reconnect + backoff + ping + resubscribe | **glue** — daemon chose 60s poll |
| e | **Presence / read-receipts** | ✅ (partial presence) | Read receipts: `sendReadReceipt` (kind 15). Typing/presence + unread/markAsRead: `CommunicationsModule` (`ComposingIndicator`, `getDMUnreadCount`, `markAsRead`) | **glue** — helper uses neither |
| f | **Delivery guarantees / relay redundancy** | ⚠️ Best-effort + redundancy | Multi-relay `connect(...urls)`, broadcast-to-all, NIP-20 OK tracking (`pendingOks`), event queue + flush, `ConnectionEventListener` | partial SDK — no store-and-forward ack beyond app-level read receipts |

Legend: **glue** = SDK supports it, `sphere-helper.mjs` just doesn't call it. **partial SDK** = a real SDK ceiling.

---

## 2. Detailed findings & exact API calls

### (a) NIP-17 DMs — READY, already wired
`NostrClient` (nostr-js-sdk) fully implements the gift-wrap flow (Rumor kind 14 → Seal kind 13 → Gift-Wrap kind 1059, NIP-44 sealed):
```js
const client = new NostrClient(keyManager, { autoReconnect: true });
await client.connect('wss://nostr-relay.testnet.unicity.network');
await client.sendPrivateMessage(recipientPubkeyHex, text, { replyToEventId }); // → eventId
const msg = client.unwrapPrivateMessage(giftWrapEvent);  // { senderPubkey, content, timestamp, kind, replyToEventId }
```
`isChatMessage(msg)` / `isReadReceipt(msg)` classify kind 14 vs 15. This is exactly what the working `send-dm` / `check-messages` glue already uses.

### (b) NIP-29 groups — READY at high level; helper stub is the only blocker
sphere-sdk 0.4.3 ships a **complete `GroupChatModule`** (confirmed in `dist/index.d.ts`, class at L3369; factory `createGroupChatModule`; also exported: `GroupRole`, `GroupVisibility`, `CreateGroupOptions`, `NIP29_KINDS`, `DEFAULT_GROUP_RELAYS`). Public methods:
```
fetchAvailableGroups() joinGroup(groupId, inviteCode?) leaveGroup(groupId)
createGroup(options) deleteGroup(groupId) createInvite(groupId)
sendMessage(groupId, content, replyToId?) fetchMessages(groupId, since?, limit?)
getMessages/getMembers/getGroups  onMessage(handler)  // real-time push
kickUser/deleteMessage/markGroupAsRead  isCurrentUserAdmin/…Role  connect()/getConnectionStatus()
```
It handles relay-managed membership (join requests, 39002 member lists, moderation kinds, relay-admin detection), debounced persistence, and auto-reconnect internally. **De-stubbing `join-group` = replacing the fake "configured" output with a real `GroupChatModule` init + `joinGroup()`/`onMessage()`.** No protocol work needed.

> Note: the *low-level* path the helper's `check-messages` uses (subscribe to raw kind-9 with `#h` group tag via `Filter`) also works for *open* groups and is a valid lightweight alternative to the full module.

### (c) Nametag resolve/register — RESOLVE is a one-liner; helper stub never calls it
The `resolve-nametag` stub only computes `hashNametag()` and returns `npub: null`. But nostr-js-sdk already provides the resolver:
```js
const pubkeyHex = await client.queryPubkeyByNametag(nametag); // string | null
// then npub via Bech32: sdk.encodeBech32('npub', 0, hexToBytes(pubkeyHex))
```
Register:
```js
await client.publishNametagBinding(nametagId, unicityAddress); // kind 30078 (NIP-78) replaceable
```
**Upgrade payoff (0.6.0):** adds `client.queryBindingByNametag(nametag)` → `{ transportPubkey, publicKey?, l1Address?, directAddress?, proxyAddress?, nametag?, timestamp }`, and `publishNametagBinding` now **throws if the nametag is already claimed by another pubkey** (squatting protection) and distinguishes the *transport* pubkey (what you DM) from the wallet pubkey. For a bus that addresses agents by name, **`transportPubkey` from `queryBindingByNametag` is the correct target** — worth upgrading for.

### (d) Real-time — READY; the 60s poll is a daemon choice, not an SDK ceiling
`NostrClient` maintains a **persistent WebSocket** and pushes events via `NostrEventListener.onEvent` the instant a relay delivers them. Built-in resilience: `autoReconnect` (exponential backoff `reconnectIntervalMs`→`maxReconnectIntervalMs`), `pingIntervalMs` health checks, `resubscribeAll` on reconnect, queued-event flush, `ConnectionEventListener` hooks. `GroupChatModule.onMessage` and `CommunicationsModule` expose the same push semantics one layer up. The daemon's `check-messages`-every-60s loop replaces this real-time stream with polling **unnecessarily** — the fix is to hold a long-lived client and route `onEvent` straight into the hook.

### (e) Presence / read-receipts — READY
- **Read receipts:** `client.sendReadReceipt(recipientPubkeyHex, messageEventId)` (kind-15 rumor); inbound classified by `isReadReceipt()`.
- **Typing/presence + unread state:** sphere-sdk's `CommunicationsModule` (`createCommunicationsModule`) exposes `ComposingIndicator` (typing), conversation pages, `getDMUnreadCount`/`markAsRead`, `MessageHandler`. The Sphere Connect RPC surface (`GET_DM_UNREAD_COUNT`, `MARK_AS_READ`, `GET_CONVERSATIONS`) confirms this is a first-class layer.
- **Gap:** no NIP-38 "online now" liveness beacon — presence here means typing indicators + read state, not global online/offline status. Fine for a request/response bus.

### (f) Delivery guarantees / redundancy — best-effort with redundancy, no hard guarantee
`connect(...relayUrls)` fans out to multiple relays; `publishEvent` broadcasts to all connected relays and tracks per-relay NIP-20 `OK` acks (`pendingOks`); an event queue flushes on (re)connect so a transient disconnect doesn't drop a send. This gives **relay-level redundancy and at-least-once-ish publish**, but there is **no end-to-end delivered-to-recipient guarantee** — the only recipient-level ack is the app-layer **read receipt** (e). For the bus, treat read receipts as the delivery signal and add an application-level retry/timeout on top.

---

## 3. What the current glue actually uses vs. leaves on the table

`sphere-helper.mjs` (332 lines) instantiates only the **low-level `NostrClient`** (`createNostrClient`, L73) and:
- `send-dm` → `client.sendPrivateMessage` ✅ (correct)
- `check-messages` → `client.subscribe` on kind-1059 (`#p` = me) + raw kind-9 (`#h` = group), **5-second collection window then disconnect** ✅ works but throws away the persistent stream
- `resolve-nametag` → **stub**: only `hashNametag()`, returns `npub:null` — never calls `queryPubkeyByNametag`
- `join-group` → **stub**: prints `status:'configured'`, no relay interaction — ignores the entire `GroupChatModule`

It never imports `GroupChatModule`, `CommunicationsModule`, `queryPubkeyByNametag`, `sendReadReceipt`, or the connection listeners — i.e. **the four "gaps" (b,c,d,e) are unused SDK surface, not missing SDK features.**

---

## 4. Glue to write (per gap) — concrete, minimal

1. **Real-time daemon (gap d, #5):** In `sphere-daemon.mjs`, replace the 60s `check-messages` poll with a **long-lived `NostrClient`**: one `connect()`, permanent `subscribe(kind1059 #p=me)` + `subscribe(kind9 #h=group)`, route `onEvent` → existing `on-dm.sh`/`on-group-message.sh`. Add a `ConnectionEventListener` for reconnect logging. Keep the poll only as a cold-start backfill (`since` filter).
2. **De-stub `resolve-nametag` (gap c, #4):** call `client.queryPubkeyByNametag(normalized)`; return `{ nametag, hash, pubkey_hex, npub }`. On 0.6.0, prefer `queryBindingByNametag().transportPubkey`.
3. **De-stub `join-group` (gap b, #4):** init `createGroupChatModule()` with the client/keyManager deps, call `joinGroup(groupId)`, wire `onMessage` into the group hook, persist membership. (Or, for open groups, keep the raw kind-9 `#h` path already in `check-messages` and just add a kind-9 `sendMessage` publisher.)
4. **Nametag register (gap c):** new `register-nametag` subcommand → `client.publishNametagBinding(nametag, address)` so agents self-register human-readable addresses (the bus's naming layer). Handle the 0.6.0 "already-claimed" throw.
5. **Read-receipt / ack (gap e/f):** call `client.sendReadReceipt(sender, eventId)` after a message is accepted **and passes the authorization + semantic firewall** — makes the receipt a "accepted & cleared" signal, not just "arrived."
6. **Addressing helper:** the npub↔hex conversion already exists (`Bech32`/`encodeBech32`/`decodeNpub` in nostr-js-sdk) — centralize it.

**None of the above requires changes to the SDKs.** The firewall work (authorization + semanticd) layers *on top of* this glue at the `onEvent` boundary — the SDK gives you `senderPubkey` (from the unwrapped seal, cryptographically authenticated) and the raw `content`, which is exactly the tuple the authz firewall (is-sender-approved?) and semantic firewall (scan `content` before it reaches Claude) need.

---

## 5. Upgrade recommendation

- **Upgrade `nostr-js-sdk` 0.3.3 → 0.6.0** (low risk, high payoff): adds `queryBindingByNametag` (transport vs wallet pubkey — the *correct* bus addressing primitive) and nametag-squatting protection. This directly improves the authorization firewall (bind a nametag to exactly one authenticated pubkey).
- **Upgrade `sphere-sdk` 0.4.3 → 0.11.15 with caution:** 7 minor versions of churn on a pre-1.0 SDK; expect breaking API changes in the high-level modules. If you only need `NostrClient` + `GroupChatModule` + nametag, pin conservatively and typecheck. If adopting `CommunicationsModule`/`Sphere` for presence/unread, budget for API drift and test against the live relay (`vitest run --config vitest.relay.config.ts` exists in the package).
- **For Concierge (separate repo, zero-runtime-dep rule):** these SDKs are npm deps and must follow the sanctioned-exception pattern — **isolated in a single module + lazy-imported via a non-literal specifier** (same as `wallet/sphere.ts` and `x402/signing.ts`), so an absent package fails only at call time as a 503. That gives the Concierge↔claude bus bridge (gap #6) a clean seam.

## 6. Verdict

**The SDK is READY to power the universal DM bus today.** Transport-layer capabilities a–e are all present in the *installed* version; only f (hard delivery guarantee) has a real ceiling, mitigated by read-receipt acks + app-level retry. The bus's remaining work is **glue + the two firewalls**, not SDK gaps:
- de-stub `resolve-nametag` (1 call) and `join-group` (use `GroupChatModule`),
- convert the daemon from 60s poll to the SDK's real-time `subscribe` stream,
- add nametag register + read-receipt acks,
- and layer the authorization + semanticd firewalls at the `onEvent`/`unwrapPrivateMessage` boundary.

Upgrade `nostr-js-sdk` to 0.6.0 for `queryBindingByNametag` (transport-pubkey addressing + squatting protection); treat the sphere-sdk 0.4.3→0.11.15 jump as a separate, tested migration.