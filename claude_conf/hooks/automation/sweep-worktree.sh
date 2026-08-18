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

# Never block on a credential prompt at 3 AM (would hang holding the run-job flock).
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}"

MAIN_REF="${SWEEP_MAIN_REF:-origin/main}"
PRUNE_DAYS="${SWEEP_PRUNE_DAYS:-7}"
NET_TO="${SWEEP_NET_TIMEOUT:-300}"
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

# true if this repo already has a live sweep worktree under OUR sweep base dir
# (a prior night's crash). Scoped to the base dir — NOT the global sweep/* branch
# namespace — so a human's unrelated `sweep/foo` checkout never wedges the job,
# and a crashed DETACHED worktree (create crashed before `switch`) is still caught.
_has_sweep_worktree() { # <repo-abspath> <base-dir>
  local repo="$1" bd="$2" p
  while IFS= read -r p; do
    case "$p" in "worktree "*) p="${p#worktree }"; case "$p" in "$bd"/*) return 0 ;; esac ;; esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  return 1
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
  # belt-and-suspenders scrub (a name-based top-level filter is not enough):
  #  1. drop the identity dir outright.
  rm -rf "$dst/agent" 2>/dev/null || true
  #  2. remove EVERY symlink — a link named innocently (cp -a preserves links,
  #     never dereferences) could point at the real .secrets/$HOME outside the wt.
  find "$dst" -type l -delete 2>/dev/null || true
  #  3. scrub secret-bearing files at ANY depth (not just maxdepth 2).
  find "$dst" \( -name '.env' -o -name '.env.*' -o -name '.secrets' -o -name 'agent' \
       -o -name 'id_rsa' -o -name 'id_ed25519' -o -name 'id_ecdsa' \
       -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' -o -name '*.keystore' \) \
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

    # 2. refresh origin (bounded; never prompts) and require the base ref.
    timeout "$NET_TO" git -C "$repo" fetch origin --quiet 2>/dev/null || _sw_log "warn: git fetch origin failed/timed out — using cached refs"
    git -C "$repo" rev-parse --verify -q "$MAIN_REF" >/dev/null 2>&1 \
      || _sw_die "create: $MAIN_REF does not resolve — cannot base a sweep on it"

    date="$(_date)"; bd="$(_base_dir "$repo")"; wt="$bd/$date"

    # 3. collision → skip tonight (do not stack on a prior crashed run). Scoped to
    #    OUR base dir, and catches a detached leftover too.
    if _has_sweep_worktree "$repo" "$bd"; then
      _sw_log "a sweep worktree already exists under $bd — skip (collision)"; exit 3
    fi
    if [ -e "$wt" ]; then
      _sw_log "sweep dir already exists ($wt) — skip (collision)"; exit 3
    fi

    # 4. create the worktree off origin/main ON the dated sweep branch in ONE step
    #    (no detached window a crash could leak; -B resets a stale same-date ref).
    mkdir -p "$bd" 2>/dev/null || _sw_die "create: cannot make sweep base $bd"
    if ! git -C "$repo" worktree add -B "sweep/$date" "$wt" "$MAIN_REF" >/dev/null 2>&1; then
      git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt" 2>/dev/null || true
      _sw_die "create: git worktree add failed"
    fi

    # 5. materialize .claude (minus agent/secrets) so the safety hooks are LIVE.
    _copy_claude_min_agent "$repo" "$wt" || _sw_log "warn: .claude copy incomplete"

    _sw_log "created sweep worktree $wt on branch sweep/$date (base $MAIN_REF)"
    printf '%s\n' "$wt"
    exit 0 ;;

  destroy)
    [ -n "${1:-}" ] || _sw_die "destroy: need <worktree>"
    wt="$1"
    # discover the owning repo + branch from the worktree's gitdir BEFORE removal
    # (so we can prune siblings and delete the branch ref, which otherwise piles up).
    repo=""; br=""
    if [ -d "$wt" ]; then
      # --git-common-dir points at the MAIN repo's .git; its parent is the repo.
      cdir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
      [ -n "$cdir" ] && repo="$(cd "$cdir/.." 2>/dev/null && pwd || echo "")"
      br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi
    # fall back to two-levels-up if git couldn't resolve the repo, so we still prune.
    [ -z "$repo" ] && repo="$(cd "$(dirname "$(dirname "$wt")")" 2>/dev/null && pwd || echo "")"
    if [ -n "$repo" ] && [ -d "$repo" ]; then
      git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
      git -C "$repo" worktree prune 2>/dev/null || true
      case "$br" in sweep/*) git -C "$repo" branch -D "$br" 2>/dev/null || true ;; esac
    fi
    rm -rf "$wt" 2>/dev/null || true
    # 7-day prune of the sibling sweep dirs for this repo.
    [ -n "$repo" ] && [ -d "$repo" ] && _prune "$repo"
    _sw_log "destroyed sweep worktree $wt${br:+ (branch $br)}"
    exit 0 ;;

  ""|-h|--help|help)
    sed -n '2,30p' "$0"; exit 0 ;;
  *)
    _sw_die "unknown subcommand: $cmd (create|destroy|prune|marker-read|marker-write|slug|base)" ;;
esac
