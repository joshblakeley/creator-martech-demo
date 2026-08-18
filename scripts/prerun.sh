#!/usr/bin/env bash
# Run the example questions concurrently so their answers already exist. Run
# sequentially this takes ~8-10 minutes; concurrently it takes about as long as
# the slowest single question.
#
# Useful ahead of showing the system to someone: reading a finished answer in the
# UI is clearer than watching one stream, and there is no waiting.

. "$(dirname "$0")/_lib.sh"
require_token

QUESTIONS=(
  "Find 5 skincare micro-influencers for Lumen Skincare with a rate under 5000 USD per post."
  "Who is our top performer for Lumen Skincare by GMV? Then find and rank 3 new skincare micro creators like them, with fit scores."
  "What is our campaign ROI this month versus last month for Lumen Skincare?"
  "Which of the eligible Lumen Skincare creators is the best fit for a Q4 push, and why?"
)

log "running ${#QUESTIONS[@]} questions concurrently"
warn "note: a transcript is sometimes titled with an internal dispatch payload"
warn "      rather than the question, when the first recorded turn is a tool"
warn "      call. Nothing is lost; the context ids below are how to find them."

OUT="$STATE_DIR/prerun"; rm -rf "$OUT"; mkdir -p "$OUT"

pids=()
for i in "${!QUESTIONS[@]}"; do
  (
    start=$(date +%s)
    rpai $(rpai_cfg) agent a2a send "$AGENT_NAME" "${QUESTIONS[$i]}" -o json \
      > "$OUT/$i.json" 2>/dev/null
    cid="$(jq -r '.contextId // .result.contextId // "unknown"' "$OUT/$i.json" 2>/dev/null)"
    printf '  [%3ds] %-62s  %s\n' "$(( $(date +%s) - start ))" "${QUESTIONS[$i]:0:62}" "$cid"
  ) &
  pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do wait "$pid" || fail=$((fail+1)); done

if [ "$fail" -gt 0 ]; then
  warn "$fail question(s) failed — check 'make status' and re-run"
else
  ok "all questions pre-run; transcripts are in the ADP UI under agent '$AGENT_NAME'"
fi
