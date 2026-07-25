# Nostr DM fix — technical notes

Branch: `fix/nostr-dm-identity-encoding` in `~/claude_unicity_setup`.

## Root cause: four stacked bugs

| # | Bug | Effect |
|---|---|---|
| A | `create-identity` called sphere-sdk's `encodeBech32('npub', 0, key)` instead of nostr-js-sdk's `encodeNpub(key)`. The sphere-sdk encoder is L1-style (Bitcoin SegWit) and inserts a witness-version byte before the data. | Every agent npub decoded to 33 bytes instead of 32. Standard `decodeNpub` (and the `decodeNsec` for the matching nsec) threw `Expected 32 bytes, got 33`. |
| B | Same encoder used for nsec → same 33-byte breakage. | `NostrKeyManager.fromNsec(identity.nsec)` always threw on every existing identity file. |
| C | `client.subscribe(filter, (event) => {...})` passes a bare callback. `NostrClient.handleEventMessage` calls `subscription.listener.onEvent(event)`; bare function has no `.onEvent`, throws, swallowed by an empty `catch{}`. | Receiver subscriptions silently ate every event. `check-messages` always returned `{messages: []}`, even when the gift wrap was definitely on the relay (verified by direct WS query). |
| D | NIP-17 gift wraps randomize `created_at` by ±2 days for privacy. Helper subscribed with `since = now - 600s`. | Even if (C) were fixed, ~half the gift wraps would be filtered out by the relay because their `created_at` is in the past. |

The original brief's `Expected 32 bytes, got 33` masked bugs C and D — the helper never actually got far enough to test the subscription path because step 1 always died.

The Unicity nostr-js-sdk is internally consistent and standards-compliant (NIP-19, NIP-44, BIP-340). The breakage was entirely in the helper.

## What was changed

`lib/sphere-helper.mjs`:

- `createIdentity`: switched npub/nsec encoders to `nostr.encodeNpub` / `nostr.encodeNsec`. New identities produce standard 32-byte NIP-19 strings.
- `deriveNostrPrivateKey` (new): derives the 32-byte private key from `mnemonic` (preferred), `private_key` hex, or `nsec` (with legacy L1-style fallback). The legacy fallback uses `sphereSdk.decodeBech32`, which transparently strips the witness-version byte.
- `createNostrClient`: now always derives a fresh 32-byte key — never calls `NostrKeyManager.fromNsec` directly on a possibly-legacy nsec.
- `npubToHex`: accepts (a) bare 64-hex x-only, (b) bare 66-hex compressed `02/03`-prefixed, (c) standard NIP-19 npub, (d) legacy L1-style npub (33 bytes). All paths normalize to 64-hex x-only.
- `checkMessages`: wraps DM and group callbacks in `{ onEvent }` objects; widens DM `since` to `userSince - 2d` to absorb NIP-17 timestamp randomization; post-filters by rumor (truthful) timestamp; deduplicates by event id across both subscriptions.
- `migrateIdentity` (new subcommand): re-derives canonical npub/nsec for an existing identity file. Idempotent. Defaults to dry-run; pass `--write` to apply. Creates `identity.json.bak` unless `--no-backup`.
- `npubToHexCommand` (new `npub-to-hex` subcommand): prints canonical 32-byte x-only hex on stdout for any of the four input forms above. No JSON wrapper — for shell consumers (the hooks).

Public key (`public_key` field) and `mnemonic` were always correct — migration only touches `npub`, `nsec`, and writes `private_key` (computed from mnemonic for completeness).

`claude_conf/hooks/on-dm.sh` and `claude_conf/hooks/on-group-message.sh`:

- Both hooks previously compared the incoming sender (32-byte x-only hex from the daemon's NIP-17-unwrapped message) to `owner_npub` (bech32 string from `config.json`) — they could never match, so owner-priority alerting was dead code, and the own-message filter in the group hook always leaked own messages into the inbox.
- Fix: shell out to `sphere-helper.mjs npub-to-hex` once at startup to decode `owner_npub` and (for the group hook) `identity.npub` into canonical 32-byte hex. Compare hex-to-hex. The same helper handles standard NIP-19, legacy L1-style, and bare-hex inputs, so the hooks keep working through any future migration.
- on-dm.sh also respects a `priority: true` field if the daemon-side helper already computed it (avoids re-doing the decode), with the local hex-to-hex compare as a defensive fallback.
- The bug was masked because `owner_npub` is empty (`""`) in every observed config, so the dead priority paths just no-op'd. Verified by 11 unit tests covering: empty owner, standard npub owner, legacy npub owner, non-owner sender, helper-supplied priority flag, own-message drop, owner group msg, missing config file — all pass.

## What was verified

- Send UXF → sphere.telco DM: arrives, decrypts, content matches.
- Send with legacy 33-byte npub recipient: still works (falls through legacy decode path).
- Send with `nsec`-only legacy identity file: still works (falls through legacy nsec decode path).
- `create-identity` produces standards-compliant 32-byte npub/nsec.
- `migrate-identity` is idempotent on already-migrated files.
- All 16 agent identities under `~/*/.claude/agent/identity.json` migrated; backups saved as `.bak`.

## What was NOT changed (out of scope, deliberate)

1. **`@unicitylabs/nostr-js-sdk`** — unchanged. It is correct. Considered patching to accept 33-byte keys for compatibility, decided against: x-only public keys are required by Schnorr (BIP-340) and NIP-44 ECDH; transparently stripping the parity byte would silently change signatures. The right fix is to never produce 33-byte npub/nsec in the first place.
2. **sphere-sdk's `CommunicationsModule`, `NostrTransportProvider`** — untouched. These also pass bare functions to `client.subscribe()` in many places; they are affected by the same listener-shape bug. Separate work — flagging only.

## Follow-ups for the team

1. Audit and fix subscribe-listener shape in sphere-sdk `NostrTransportProvider` and `CommunicationsModule`. Same pattern, same bug, same impact (silent message loss).
2. The DM polling window in any consumer of NIP-17 gift wraps must widen by 2 days to absorb the privacy-randomized `created_at`. Document this in the sphere-sdk integration guide.
3. `decodeNpub` could be extended in nostr-js-sdk to accept 33-byte legacy input and silently strip the leading version byte for backward compat — but this would mask future bugs, so a strict check is probably the right call. Document the legacy format and provide a migration helper (this helper now exists).
