#!/usr/bin/env bash
# Print the agent manifest on stdout, with the prompts read in from
# config/system-prompt.md and config/subagents/*.md.
#
# The prompts stay as separate markdown files because that is where they are
# actually edited and reviewed — inlining sixty lines of instructions into YAML
# makes them unreadable. This assembles the two into one manifest, which
# `rpai agent apply -f -` reconciles.
#
# The manifest shape is a `rpai agent get <name> -o yaml` dump: the resource
# itself, led by @type.

. "$(dirname "$0")/_lib.sh"
cd "$ROOT"

# Each specialist's description is passed through verbatim as the tool
# description the orchestrator reads when deciding who to hand a question to.
# A plain-English sentence about when an agent applies is the routing rule.
SCOUT_DESC="Intent involves discovering or shortlisting creators. Applies hard filters (category, audience size, budget, brand safety) against the creator list and returns eligible candidates plus excluded candidates with the reason each failed."
FIT_DESC="Intent involves ranking, comparing, or picking the best creator(s). Returns a 1-100 fit score per creator with the six measures (1-10) behind it."

# SCOUT_MODEL runs the filtering specialist on a smaller model. Leave it blank to
# use the same one as the orchestrator, which is the recommendation — a smaller
# model picked noticeably worse shortlists when tried.
scout_model_line=""
[ -n "${SCOUT_MODEL:-}" ] && scout_model_line="    model: $SCOUT_MODEL"

python3 - "$AGENT_NAME" "$AGENT_DISPLAY_NAME" "$LLM_MODEL" "$LLM_PROVIDER" \
          "$MCP_CAMPAIGN" "$MCP_CREATOR" "$MCP_FIT" "$ENV" \
          "$SCOUT_DESC" "$FIT_DESC" "${SCOUT_MODEL:-}" <<'PY'
import sys, yaml, pathlib

# Emit the long prompts as YAML block scalars rather than escaped one-liners, so
# the rendered manifest is readable when someone inspects it.
def _str(dumper, data):
    style = "|" if "\n" in data else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)
yaml.add_representer(str, _str)

(name, display, model, provider, mcp_campaign, mcp_creator, mcp_fit,
 env, scout_desc, fit_desc, scout_model) = sys.argv[1:12]

read = lambda p: pathlib.Path(p).read_text()

scout = {
    "description": scout_desc,
    "system_prompt": read("config/subagents/influencer-scout.md"),
    "mcp_servers": [mcp_creator],
}
if scout_model:
    scout["model"] = scout_model

doc = {
    "@type": "type.googleapis.com/redpanda.api.adp.v1alpha1.Agent",
    "name": name,
    "display_name": display,
    "description": ("Creator matchmaking orchestrator. Answers campaign questions "
                    "directly; hands discovery to influencer-scout and ranking to "
                    "fit-scoring."),
    "tags": {"demo": "creator-martech", "owner": "creator-martech-demo", "env": env},
    "managed": {
        "spec": {
            "model": model,
            "llm_provider": provider,
            "system_prompt": read("config/system-prompt.md"),
            # The orchestrator's own servers. Each specialist's are chosen
            # independently rather than being a subset, so the orchestrator
            # genuinely cannot reach the creator list.
            "mcp_servers": [mcp_campaign],
            "subagents": {
                "influencer-scout": scout,
                "fit-scoring": {
                    "description": fit_desc,
                    "system_prompt": read("config/subagents/fit-scoring.md"),
                    "mcp_servers": [mcp_fit],
                },
            },
            "max_iterations": 12,
        }
    },
}

print(yaml.dump(doc, sort_keys=False, default_flow_style=False,
                width=100, allow_unicode=True))
PY
