#!/bin/bash
# Shared helper: compute a per-repo $STATE_DIR for hook coordination files so two
# Claude sessions in different repos don't collide on the shared /tmp/claude path.
# Key derives from THIS hooks dir's location (../.. = repo root) rather than
# CLAUDE_PROJECT_DIR, because some daemon-invoked hooks (on-dm.sh, on-group-message.sh)
# lack CLAUDE_PROJECT_DIR — but all hooks in a repo share the same .claude/hooks path.
# Source it:  . "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
# Guarded with `|| true` so it's safe to source under callers' `set -euo pipefail`.
_csd_src="${BASH_SOURCE[0]:-$0}"
_csd_root="$(cd "$(dirname "$_csd_src")/../.." 2>/dev/null && pwd || true)"
[ -n "$_csd_root" ] || _csd_root="${CLAUDE_PROJECT_DIR:-/tmp}"
_csd_key="$(printf '%s' "$_csd_root" | sha1sum 2>/dev/null | cut -c1-12 || true)"
[ -n "$_csd_key" ] || _csd_key="default"
STATE_DIR="/tmp/claude/$_csd_key"
mkdir -p "$STATE_DIR" 2>/dev/null || true
