#!/bin/bash
# Runner for the A2A poller NIP-59 gift-wrap fix unit tests (node:test). Wraps the
# .mjs so it is discovered/executed the same way as the other test/*.test.sh scripts.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
exec node --test "$REPO/test/poller-nip59.test.mjs"
