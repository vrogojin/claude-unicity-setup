#!/bin/bash
# sweep-worktree.sh — deterministic git-worktree lifecycle for the nightly
# housekeeping sweep (design §5.2). The sweep NEVER works in the live checkout:
# it gets its own disposable worktree off origin/main with its own HEAD, so it
# can't collide with a human or another agent sitting on the shared checkout
# (the single-shared-checkout rule is the *reason* for this design). No secrets
# ever enter the worktree.
#
# Subcommands:
#   create  <repo>            fetch origin, make ~/.claude/sweeps/<slug>/<date>
#                             off origin/main, switch to sweep/<date>, copy
#                             .claude/ MINUS agent/ (so the safety hooks fire in
#                             the sweep session) and NO .env/.secrets. Prints the
#                             worktree path on stdout. Exit: 0 ok · 3 collision
#                             (a prior night's worktree still exists → skip, do
#                             not stack) · 1 error.
#   destroy <worktree>        git worktree remove --force + prune + 7-day prune.
#   prune   <repo>            7-day sweep-dir prune only (also run inside create).
#   marker-read  <repo>       print the last-sweep sha (empty if none).
#   marker-write <repo> <sha> record {sha, at} as the next run's scope floor.
#   slug   <repo>             print the repo slug (test/introspection helper).
#   base   <repo>             print the sweep base dir (test/introspection helper).
#
# Overrides (tests): AUTOMATION_STATE_DIR (marker location), SWEEP_HOME (the
# ~/.claude/sweeps root), SWEEP_DATE (the <date> stamp), SWEEP_MAIN_REF (default
# origin/main), SWEEP_PRUNE_DAYS (default 7).
set -uo pipefail

SW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
SW_HOOKS_PARENT="$(cd "$SW_DIR/.." 2>/dev/null && pwd || echo .)"
if [ -n "${AUTOMATION_STATE_DIR:-}" ]; then
  STATE_DIR="$AUTOMATION_STATE_DIR"
else
  . "$SW_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
fi

_sw_log()  { echo "[sweep-worktree] $*" >&2; }
_sw_die()  { _sw_log "$*"; exit 1; }

MAIN_REF="${SWEEP_MAIN_REF:-origin/main}"
PRUNE_DAYS="${SWEEP_PRUNE_DAYS:-7}"
HK_DIR="$STATE_DIR/automation/housekeeping"

# --- helpers ------------------------------------------------------------------
_abs()  { cd "$1" 2>/dev/null && pwd; }
_slug() { # <repo-abspath> → stable, collision-free-across-same-named-repos slug
  local abs="$1" base hash
  base="$(basename "$abs")"
  hash="$(printf '%s' "$abs" | sha1sum 2>/dev/null | cut -c1-8)"
  [ -n "$hash" ] || hash="x"
  printf '%s-%s' "$base" "$hash"
}
_sweep_root() { printf '%s' "${SWEEP_HOME:-$HOME/.claude/sweeps}"; }
_base_dir()   { printf '%s/%s' "$(_sweep_root)" "$(_slug "$1")"; }
_date()       { printf '%s' "${SWEEP_DATE:-$(date +%Y%m%d)}"; }

# prune sweep dirs older than PRUNE_DAYS for THIS repo; keep git registration honest.
_prune() { # <repo-abspath>
  local repo="$1" bd; bd="$(_base_dir "$repo")"
  git -C "$repo" worktree prune 2>/dev/null || true
  [ -d "$bd" ] || return 0
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    git -C "$repo" worktree remove --force "$d" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
    _sw_log "pruned stale sweep dir (>${PRUNE_DAYS}d): $d"
  done < <(find "$bd" -mindepth 1 -maxdepth 1 -type d -mtime "+$PRUNE_DAYS" 2>/dev/null)
  git -C "$repo" worktree prune 2>/dev/null || true
}

# true if the repo already has a live sweep/* worktree (a prior night's crash).
_has_sweep_worktree() { # <repo-abspath>
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^branch /{ if ($2 ~ /^refs\/heads\/sweep\//) { print; exit } }' \
    | grep -q .
}

# copy repo/.claude into the worktree, EXCLUDING agent/ and any secret material.
# REQUIRED: hooks resolve via $CLAUDE_PROJECT_DIR/.claude/hooks/… and with cwd =
# worktree an absent .claude would SILENTLY disable branch-guard + pre-commit
# (§6 row 6 depends on them). NEVER copy/link .env / .secrets / .claude/agent.
_copy_claude_min_agent() { # <repo-abspath> <worktree>
  local repo="$1" wt="$2"
  local src="$repo/.claude" dst="$wt/.claude"
  [ -d "$src" ] || { _sw_log "warn: no .claude at $src — safety hooks may not fire in sweep"; return 0; }
  mkdir -p "$dst" 2>/dev/null || return 1
  local entry name
  for entry in "$src"/* "$src"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in
      agent) continue ;;                    # identity/registry — NEVER in the sweep
      .env|.env.*|.secrets) continue ;;     # secrets — NEVER in the sweep
    esac
    cp -a "$entry" "$dst/" 2>/dev/null || cp -r "$entry" "$dst/" 2>/dev/null || true
  done
  # belt-and-suspenders: scrub anything sensitive that slipped through a glob edge.
  rm -rf "$dst/agent" 2>/dev/null || true
  find "$dst" -maxdepth 2 \( -name '.env' -o -name '.env.*' -o -name '.secrets' \) \
    -exec rm -rf {} + 2>/dev/null || true
  return 0
}

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  slug) [ -n "${1:-}" ] || _sw_die "slug: need <repo>"; _slug "$(_abs "$1")"; echo; exit 0 ;;
  base) [ -n "${1:-}" ] || _sw_die "base: need <repo>"; _base_dir "$(_abs "$1")"; echo; exit 0 ;;

  marker-read)
    [ -n "${1:-}" ] || _sw_die "marker-read: need <repo>"
    jq -r '.sha // empty' "$HK_DIR/last-sweep.json" 2>/dev/null || true
    exit 0 ;;

  marker-write)
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || _sw_die "marker-write: need <repo> <sha>"
    mkdir -p "$HK_DIR" 2>/dev/null || true
    if jq -n --arg sha "$2" --arg at "$(date -u +%FT%TZ)" '{sha:$sha, at:$at}' \
         > "$HK_DIR/last-sweep.json.tmp" 2>/dev/null; then
      mv "$HK_DIR/last-sweep.json.tmp" "$HK_DIR/last-sweep.json"
    else
      rm -f "$HK_DIR/last-sweep.json.tmp"; _sw_die "marker-write: could not write marker"
    fi
    exit 0 ;;

  prune)
    [ -n "${1:-}" ] || _sw_die "prune: need <repo>"
    repo="$(_abs "$1")" || _sw_die "prune: no such repo dir: $1"
    _prune "$repo"; exit 0 ;;

  create)
    [ -n "${1:-}" ] || _sw_die "create: need <repo>"
    repo="$(_abs "$1")" || _sw_die "create: no such repo dir: $1"
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || _sw_die "create: $repo is not a git repo"

    # 1. self-heal: prune ancient sweep dirs BEFORE the collision check so a
    #    week-old crashed worktree can't wedge every future sweep.
    _prune "$repo"

    # 2. refresh origin and require the base ref to resolve.
    git -C "$repo" fetch origin --quiet 2>/dev/null || _sw_log "warn: git fetch origin failed — using cached refs"
    git -C "$repo" rev-parse --verify -q "$MAIN_REF" >/dev/null 2>&1 \
      || _sw_die "create: $MAIN_REF does not resolve — cannot base a sweep on it"

    date="$(_date)"; bd="$(_base_dir "$repo")"; wt="$bd/$date"

    # 3. collision → skip tonight (do not stack on a prior crashed run).
    if _has_sweep_worktree "$repo"; then
      _sw_log "a sweep/* worktree already exists for this repo — skip (collision)"; exit 3
    fi
    if [ -e "$wt" ]; then
      _sw_log "sweep dir already exists ($wt) — skip (collision)"; exit 3
    fi

    # 4. create the worktree off origin/main and switch to the dated sweep branch.
    mkdir -p "$bd" 2>/dev/null || _sw_die "create: cannot make sweep base $bd"
    # Silence git's chatter entirely — stdout is reserved for the worktree path.
    if ! git -C "$repo" worktree add --detach "$wt" "$MAIN_REF" >/dev/null 2>&1; then
      _sw_die "create: git worktree add failed"
    fi
    if ! git -C "$wt" switch -C "sweep/$date" >/dev/null 2>&1; then
      git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      _sw_die "create: could not switch to sweep/$date"
    fi

    # 5. materialize .claude (minus agent/secrets) so the safety hooks are LIVE.
    _copy_claude_min_agent "$repo" "$wt" || _sw_log "warn: .claude copy incomplete"

    _sw_log "created sweep worktree $wt on branch sweep/$date (base $MAIN_REF)"
    printf '%s\n' "$wt"
    exit 0 ;;

  destroy)
    [ -n "${1:-}" ] || _sw_die "destroy: need <worktree>"
    wt="$1"
    # discover the owning repo from the worktree's gitdir so we can prune siblings.
    repo=""
    if [ -d "$wt" ]; then
      # --git-common-dir points at the MAIN repo's .git; its parent is the repo.
      cdir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
      [ -n "$cdir" ] && repo="$(cd "$cdir/.." 2>/dev/null && pwd || echo "")"
    fi
    if [ -n "$repo" ] && [ -d "$repo" ]; then
      git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
      git -C "$repo" worktree prune 2>/dev/null || true
    fi
    rm -rf "$wt" 2>/dev/null || true
    # 7-day prune of the sibling sweep dirs for this repo.
    [ -n "$repo" ] && [ -d "$repo" ] && _prune "$repo"
    _sw_log "destroyed sweep worktree $wt"
    exit 0 ;;

  ""|-h|--help|help)
    sed -n '2,30p' "$0"; exit 0 ;;
  *)
    _sw_die "unknown subcommand: $cmd (create|destroy|prune|marker-read|marker-write|slug|base)" ;;
esac
