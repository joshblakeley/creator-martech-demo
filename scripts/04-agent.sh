#!/usr/bin/env bash
# Reconcile the orchestrator and its two specialists.
#
#   creator-insights-orchestrator   campaign-sql  (rollups only)
#   ├─ influencer-scout             creator-sql
#   └─ fit-scoring                  fit-sql
#
# Each specialist has its OWN MCP servers, chosen independently of the
# orchestrator's rather than being a subset of them. So the orchestrator
# genuinely cannot reach the creator list: it is not in its set, and its
# database login has no permission for it either way.
#
# `rpai agent apply` creates the agent if absent, otherwise updates only the
# fields that differ. So editing a prompt and re-running does not tear the agent
# down — which it used to, because partial updates by hand were unreliable.
#
# The manifest is assembled by scripts/render-agent.sh, which reads the prompts
# from config/. Run that on its own to see exactly what will be applied.

. "$(dirname "$0")/_lib.sh"
require_token

[[ "$AGENT_NAME" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || die "AGENT_NAME must be a DNS-1123 label; got '$AGENT_NAME'"

MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
bash "$ROOT/scripts/render-agent.sh" > "$MANIFEST"

log "diff against live"
rpai $(rpai_cfg) agent diff -f "$MANIFEST" || true

log "applying"
rpai $(rpai_cfg) agent apply -f "$MANIFEST"

log "waiting for the agent to start"
URL=""
for _ in $(seq 1 60); do
  GET="$(rpai $(rpai_cfg) agent get "$AGENT_NAME" -o json 2>/dev/null || true)"
  case "$(echo "$GET" | jq -r '.managed.status.state // ""')" in
    AGENT_STATE_RUNNING)
      URL="$(echo "$GET" | jq -r '.managed.status.url // ""')"
      ok "running"; break ;;
    AGENT_STATE_FAILED)
      die "agent failed to start: $(echo "$GET" | jq -r '.managed.status.stateReason // ""')" ;;
  esac
  sleep 5
done

[ -n "$URL" ] || URL="$AIGW_URL/a2a/v1/$AGENT_NAME"
mkdir -p "$STATE_DIR"
echo "$AGENT_NAME" > "$STATE_DIR/agent_name"
echo "$URL"        > "$STATE_DIR/agent_url"

ok "agent: $AGENT_NAME"
ok "url:   $URL"
