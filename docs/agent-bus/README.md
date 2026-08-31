# Unicity DM — Secure Agent Bus (design + red-team)

A Fable-designed architecture for turning **Unicity DM** (Nostr NIP-17 DMs + NIP-29
groups over `@unicitylabs/sphere-sdk`) into a **universal, secure bus** interconnecting
Claude Code agents, Concierge agents, and humans — with an **authorization firewall**
(trust tiers + new-contact approval), a **semantic firewall** (Unicity's `semanticd` /
SIF gateway), an autonomous responder ("team agent") hook, Concierge integration, and a
per-project coordinator / "AI-org" topology.

Produced by a 7-agent research+design+red-team workflow (2026-07-21).

## Read in this order
1. [`design.md`](design.md) — the architecture, config schemas, exact file changes, and the P0→P4 roadmap.
2. [`redteam.md`](redteam.md) — 21-finding adversarial review. **The design's headline claims are corrected here** (F1 forgeable envelope, F2 responder lethal-trifecta, F3 provenance laundering). Contains the 8 MUST-FIX-before-P0 items. Read before building.

## Supporting research
- [`research/01-setup-audit.md`](research/01-setup-audit.md) — ground-truth audit of the current `claude_unicity_setup` messaging path (WORKS/STUB/MISSING + 4 bugs).
- [`research/02-sphere-sdk-readiness.md`](research/02-sphere-sdk-readiness.md) — what the installed SDK (0.4.3 / nostr 0.3.3) supports vs. what's unwritten glue.
- [`research/03-semanticd-reference.md`](research/03-semanticd-reference.md) — the SIF `/api/v1/guard` REST reference + deployment.
- [`research/04-injection-defense-sota.md`](research/04-injection-defense-sota.md) — SOTA defending agent-to-agent messages from prompt injection.
- [`research/05-multiagent-org-sota.md`](research/05-multiagent-org-sota.md) — SOTA cross-host multi-agent "AI organization" topologies + feasibility.

## Status
Design + red-team only — **no bus code yet**. P0 (minimal secure DM: both firewalls +
non-forgeable envelope + bug fixes + real-time daemon) is the next, separately-tracked
implementation task, and must incorporate the 8 red-team P0 fixes.
