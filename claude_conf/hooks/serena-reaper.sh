#!/bin/bash
# serena-reaper.sh — SessionStart hook: reap ORPHANED Serena MCP containers.
#
# THE LEAK IT FIXES. Serena runs per Claude Code session as
# `docker run --rm -i … unicity/serena:<v>`. `--rm` only fires when the CONTAINER
# process exits — and the Serena server does NOT exit on stdin EOF. So when a
# session dies uncleanly (crash, kill -9, machine sleep, terminal closed) the
# `docker run` CLIENT dies but the container keeps running, holding its whole
# language-server fleet (tsserver/rust-analyzer/gopls/clangd) resident. These
# orphans accumulate across restarts (measured on a real host: containers up 3
# days and 5 weeks with dead clients) → steady RSS growth → swap thrash → OOM.
#
# WHAT IT DOES. On SessionStart it force-removes any container labelled
# `unicity-serena` that is BOTH (a) older than a grace window (default 48h) AND
# (b) has NO live `docker run` Serena client for its project — i.e. no live
# session could still be using it. Never blocks a session; always exits 0.
#
# PROVABLE SAFETY — why we NEVER reap a live session's container:
#   * The container carries its owning session's `--project <dir>` in its argv
#     (one Serena container per project). We scan /proc for LIVE processes whose
#     command line references the Serena IMAGE (`unicity/serena` — only the
#     `docker run` CLIENT's argv contains the image ref; the in-container
#     language servers do not) and collect their `--project` dirs. That set is
#     exactly "projects with a live Serena client right now".
#   * A container is reaped ONLY when its project is NOT in that live set. If any
#     live client references the project, the container is KEPT — even if it is
#     old — because a session could be attached to it. We prefer leaking an
#     orphan over killing a live one (the memory caps in .mcp.json bound the leak
#     in the meantime).
#   * The grace window is a second, independent guard: a container younger than
#     the grace is NEVER touched, so this session's own freshly-started container
#     (age ~0) can never be reaped even during the startup race where its client
#     is not yet visible in /proc. Only >=48h containers are ever candidates, and
#     every `docker run --rm` makes a NEW container, so a >=48h container is
#     necessarily from an earlier client — never this session's.
#
# Escape hatch: SERENA_REAPER_DISABLE=1 skips entirely.
# Tunables:  SERENA_ORPHAN_MAX_AGE_HOURS (default 48), SERENA_LABEL
#            (default unicity-serena), DOCKER_BIN (default docker).
# Modes: `serena-reaper.sh` (or `start`) reaps; `list` prints candidates without
#        removing (dry run, used by tests).
# Test seams: DOCKER_BIN lets a fake docker be injected; if
#        SERENA_REAPER_LIVE_PROJECTS_FILE is set, live projects are read from it
#        (one per line) instead of scanning /proc.
set -uo pipefail

SR_MODE="${1:-start}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
SERENA_LABEL="${SERENA_LABEL:-unicity-serena}"
SERENA_IMAGE_REF="${SERENA_IMAGE_REF:-unicity/serena}"
GRACE_HOURS="${SERENA_ORPHAN_MAX_AGE_HOURS:-48}"

_sr_log() { echo "[serena-reaper] $*" >&2; }

# Fully disabled, or docker not usable here → no-op (framework is docker-optional).
[ "${SERENA_REAPER_DISABLE:-0}" = "1" ] && exit 0
command -v "$DOCKER_BIN" >/dev/null 2>&1 || exit 0
# Drain hook stdin (SessionStart delivers JSON we don't need) without blocking.
[ -t 0 ] || cat >/dev/null 2>&1 || true

# Validate the grace window is a non-negative integer; fall back to 48 otherwise.
case "$GRACE_HOURS" in ''|*[!0-9]*) GRACE_HOURS=48 ;; esac
GRACE_SECS=$(( GRACE_HOURS * 3600 ))
NOW=$(date +%s)

# --- Collect the set of projects that have a LIVE Serena docker client -------------
# One entry per `--project` dir found on a live `docker run … unicity/serena …`
# process. A container whose project is in this set is NEVER reaped.
declare -A LIVE_PROJECTS
_sr_collect_live_projects() {
  # Test override: read the live-project list from a file (one per line).
  if [ -n "${SERENA_REAPER_LIVE_PROJECTS_FILE:-}" ] && [ -f "${SERENA_REAPER_LIVE_PROJECTS_FILE}" ]; then
    while IFS= read -r p; do [ -n "$p" ] && LIVE_PROJECTS["$p"]=1; done < "$SERENA_REAPER_LIVE_PROJECTS_FILE"
    return 0
  fi
  local cl proj
  for cl in /proc/[0-9]*/cmdline; do
    [ -r "$cl" ] || continue
    # Only the `docker run` CLIENT argv contains the image ref (the in-container
    # language servers do not) → this uniquely selects live Serena clients.
    grep -qa "$SERENA_IMAGE_REF" "$cl" 2>/dev/null || continue
    # The token immediately after `--project` is the owning session's project dir.
    proj="$(tr '\0' '\n' < "$cl" 2>/dev/null | awk 'p{print; exit} $0=="--project"{p=1}')"
    LIVE_PROJECTS["${proj:-}"]=1
  done
}
_sr_collect_live_projects

# --- Enumerate our labelled containers and reap true orphans -----------------------
CANDIDATES=0; REAPED=0; KEPT_LIVE=0; KEPT_YOUNG=0
CIDS="$("$DOCKER_BIN" ps -q --no-trunc --filter "label=$SERENA_LABEL" 2>/dev/null || true)"

for cid in $CIDS; do
  [ -n "$cid" ] || continue
  CANDIDATES=$((CANDIDATES+1))

  # Age from StartedAt (RFC3339). If it can't be parsed, treat as young (skip) —
  # fail SAFE: never reap a container we can't prove is old.
  started="$("$DOCKER_BIN" inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null || true)"
  started_epoch=""
  [ -n "$started" ] && started_epoch="$(date -d "$started" +%s 2>/dev/null || true)"
  case "$started_epoch" in ''|*[!0-9]*) started_epoch="" ;; esac
  if [ -z "$started_epoch" ]; then
    KEPT_YOUNG=$((KEPT_YOUNG+1)); continue
  fi
  age=$(( NOW - started_epoch )); [ "$age" -lt 0 ] && age=0
  if [ "$age" -lt "$GRACE_SECS" ]; then
    KEPT_YOUNG=$((KEPT_YOUNG+1)); continue   # too young → never touch
  fi

  # The container's owning project = token after --project in its argv.
  cproj="$("$DOCKER_BIN" inspect -f '{{range .Args}}{{println .}}{{end}}' "$cid" 2>/dev/null \
            | awk 'p{print; exit} $0=="--project"{p=1}')"

  # A live client for this project ⇒ a session may be attached ⇒ KEEP (do not reap).
  if [ -n "${LIVE_PROJECTS[${cproj:-}]:-}" ]; then
    KEPT_LIVE=$((KEPT_LIVE+1))
    continue
  fi

  age_h=$(( age / 3600 ))
  if [ "$SR_MODE" = "list" ]; then
    echo "$cid project=${cproj:-<none>} age=${age_h}h ORPHAN"
    REAPED=$((REAPED+1))
    continue
  fi

  if "$DOCKER_BIN" rm -f "$cid" >/dev/null 2>&1; then
    REAPED=$((REAPED+1))
    _sr_log "reaped orphan ${cid:0:12} (project ${cproj:-<none>}, age ${age_h}h, no live client)"
  else
    _sr_log "failed to remove ${cid:0:12} (project ${cproj:-<none>}, age ${age_h}h) — leaving in place"
  fi
done

if [ "$CANDIDATES" -gt 0 ]; then
  _sr_log "scan: $CANDIDATES labelled container(s) — reaped $REAPED, kept $KEPT_LIVE live, $KEPT_YOUNG young/unparseable"
fi
exit 0
