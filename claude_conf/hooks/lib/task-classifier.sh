#!/bin/bash
# task-classifier.sh — the shared "is this prompt a real make-something task?"
# detector, factored VERBATIM out of recall-prior-work.sh (C1). Two consumers
# source it: the recall hook (prior-work advisory) and the task-lifecycle hook
# (F2 start-detection). One classifier, two consumers, zero duplication.
#
# NOTHING here reads stdin, exits the process, or prints anything the caller did
# not ask for — it is a pure sourceable library of functions the hooks compose.
# The gates, the stopword set, the keyword-extraction pipeline, and the task-id
# hash are byte-for-byte the same logic recall-prior-work.sh shipped inline, so
# the refactor is behavior-preserving (proven by the parity test in
# test/task-lifecycle.test.sh, which diffs this lib's output against the
# pre-refactor hook across a corpus).
#
# API:
#   tc_intent_ok "<prompt>"    -> exit 0 iff the prompt reads as make-something
#                                 intent (slash-command skip, >=20 chars, one of
#                                 the intent verbs on a word boundary).
#   tc_keywords "<prompt>"     -> print the distinctive keywords, one per line
#                                 (lowercased, punctuation-stripped, stopwords +
#                                 intent verbs dropped, len>=4, deduped, first 6).
#   tc_keyword_count "<prompt>"-> print the number of distinctive keywords.
#   tc_is_task "<prompt>"      -> exit 0 iff tc_intent_ok AND >=2 keywords (the
#                                 full "this is a task" verdict both hooks gate on).
#   tc_task_id "<keywords>"    -> print sha1[:16] of the keyword blob — the stable
#                                 task id, identical to the hash recall's 10-min
#                                 debounce marker uses (§4.2: "same hash").
#
# Guard against double-sourcing (both hooks may source it in one process tree).
[ -n "${_TASK_CLASSIFIER_SH:-}" ] && return 0 2>/dev/null || true
_TASK_CLASSIFIER_SH=1

# Intent verbs — word-boundary alternation. Kept in one place so a future verb
# addition lands in both consumers at once.
TC_INTENT_VERBS='implement|build|add|create|fix|wire|integrate|support|introduce|rework|refactor|feature|bug'

# Stopwords dropped from keyword extraction. Includes the intent verbs themselves
# (a task about "the fix" should not key on "fix"). Byte-identical to the set
# recall-prior-work.sh shipped inline.
TC_STOP='the|this|that|with|from|into|when|then|than|them|they|there|should|would|could|please|need|needs|want|wants|make|makes|have|does|will|about|also|just|like|some|more|only|very|it|its|our|your|their|and|for|not|but|can|now|new|use|using|been|were|what|which|where|how|why|all|each|via|per|still|implement|build|add|create|fix|wire|integrate|support|introduce|rework|refactor|feature|bug'

# tc_intent_ok "<prompt>" — the intent gate (slash skip / length / verb).
tc_intent_ok() {
  local prompt="${1:-}"
  case "$prompt" in /*) return 1;; esac
  [ "${#prompt}" -ge 20 ] || return 1
  printf '%s' "$prompt" | grep -qiE "\\b(${TC_INTENT_VERBS})\\b" || return 1
  return 0
}

# tc_keywords "<prompt>" — distinctive-keyword extraction pipeline (verbatim).
tc_keywords() {
  local prompt="${1:-}"
  printf '%s' "$prompt" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '\n' \
    | grep -E '^.{4,}$' | grep -vwE "$TC_STOP" | awk '!seen[$0]++' | head -6
}

# tc_keyword_count "<prompt>" — number of distinctive keywords.
tc_keyword_count() {
  tc_keywords "${1:-}" | sed '/^$/d' | wc -l | tr -d ' '
}

# tc_is_task "<prompt>" — full verdict: intent AND >=2 distinctive keywords.
tc_is_task() {
  local prompt="${1:-}"
  tc_intent_ok "$prompt" || return 1
  [ "$(tc_keyword_count "$prompt")" -ge 2 ] 2>/dev/null || return 1
  return 0
}

# tc_task_id "<keywords>" — stable id = sha1[:16] of the newline-joined keyword
# blob. MUST match recall-prior-work.sh's debounce hash exactly (same input:
# the raw output of tc_keywords, no re-sorting), so a task and its recall share
# one id.
tc_task_id() {
  printf '%s' "${1:-}" | sha1sum 2>/dev/null | cut -c1-16
}
