#!/usr/bin/env bash
# Muse bridge watch (gongsi side, 01062283727a pair): polls the GitHub
# Atom feed of commits touching 01062283727a-to-gongsi.md. The Atom feed
# is served fresh (max-age=0), unlike raw.githubusercontent.com which
# caches for 300s and cannot be busted from the client. No secrets here;
# the script only detects a new commit SHA. The woken agent fetches old
# and new file versions through the authenticated GitHub connector,
# diffs them, decrypts new messages, and reports them.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

ATOM_URL="https://github.com/zzzz1202/muse-bridge/commits/main/01062283727a-to-gongsi.md.atom"
FILE_NAME="01062283727a-to-gongsi.md"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! curl --fail --silent --show-error --max-time 10 -A "muse-bridge-hook/1.0" "$ATOM_URL" -o "$TMP"; then
  log "fetch failed" '{"file":"01062283727a-to-gongsi.md"}'
  silent "fetch failed, will retry next poll"
fi

NEW_COMMIT="$(grep -o -m1 'Commit/[0-9a-f]\{40\}' "$TMP" | cut -d/ -f2 || true)"
if [[ -z "$NEW_COMMIT" ]]; then
  log "no commit sha in feed" '{"file":"01062283727a-to-gongsi.md"}'
  silent "feed had no commit sha, will retry next poll"
fi

STATE="$(hook_state_get)"
OLD_COMMIT="$(printf '%s' "$STATE" | jq -r '.commit // empty')"

if [[ -z "$OLD_COMMIT" ]]; then
  hook_state_set "$(jq -cn --arg commit "$NEW_COMMIT" '{commit:$commit}')"
  silent "baseline established"
fi

if [[ "$NEW_COMMIT" == "$OLD_COMMIT" ]]; then
  silent "no change"
fi

hook_state_set "$(jq -cn --arg commit "$NEW_COMMIT" '{commit:$commit}')"

PAYLOAD="$(jq -cn --arg file "$FILE_NAME" --arg prev "$OLD_COMMIT" --arg new "$NEW_COMMIT" '{file:$file, prev_commit:$prev, new_commit:$new}')"
wake "new message from 01062283727a" "$PAYLOAD"
