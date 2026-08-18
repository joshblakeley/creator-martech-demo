# creator-martech-demo

A multi-agent example built on Redpanda's Agentic Data Plane, using influencer
marketing as the domain. A question in plain language — *"find five skincare
micro-influencers under 5000 USD a post"* — returns a shortlist, a score per
creator, and the reason each near-miss was excluded.

`make up` builds everything.

All data is synthetic: the brands are invented and the 5,014 creators are
generated.

See [WALKTHROUGH.md](WALKTHROUGH.md) for things to try once it's running.

## Architecture

```
Brand Coordinator  (the only entry point)
        │
creator-insights-orchestrator ── campaign-sql ── campaign.monthly_rollup
        │                                        campaign.creator_performance
        ├─ influencer-scout ──── creator-sql  ── creator.creators, creator.brands
        └─ fit-scoring ───────── fit-sql      ── fit.creator_fit_scores
```

Three agents: an orchestrator and two specialists. Each specialist has its own
MCP server, and each server logs into Postgres as a different least-privilege
role.

The orchestrator answers campaign questions from its own views and has no
permission on the creator list. Specialists cannot be addressed directly.

Scout and scoring run concurrently; the orchestrator combines the results. The
scores view covers every creator, so scoring does not depend on the scout's
output.

The MCP servers and the agent are defined as YAML manifests in
`config/manifests/`, reconciled with `rpai mcp apply` and `rpai agent apply`.
Editing a prompt and re-running updates only what changed.

### Three access checks

| Check | Decides | Applies to |
|---|---|---|
| Postgres grant | what exists for this login | the database; a query outside it errors |
| MCP server guardrails | what a query may do | the request |
| Data policy | what this person may see | the response |

Only the data policy depends on who asked. The same question from two people
returns different data with no change to the agent, its tools or its prompt.

### Scoring

Six measures at 1–10, weighted into a score out of 100 with percentile
normalisation, defined in `config/sql/02-views.sql`. The agent reads and explains
the numbers; it does not calculate them.

The same question returns the same score. Changing the weighting is a change to
the view, not to a prompt. Hard filters are applied independently of the score —
a creator can score highly and still be excluded for being over budget.

## Requirements

- `rpai` **0.2.x or newer** (`brew install redpanda-data/tap/rpai`), `jq`, `curl`,
  `psql`, `python3`, `bash`, GNU `make`

  `rpai` is the Redpanda AI CLI, also reachable as `rpk ai` when installed as an
  rpk plugin — same binary. `make preflight` checks the version.
- A Redpanda ADP cluster with an LLM provider configured
- A Postgres reachable over the public internet with TLS. The gateway will not
  dial private addresses, so tunnels and VPC-internal databases do not work.
- Optional: a second user account in the org, to show two people receiving
  different answers at the same time. Sign it in to its own config
  (`RPAI_CONFIG=~/.rpai/contractor rpai auth login`) and pass `AS=contractor`.
  Service accounts do not work for this — the gateway treats them as
  infrastructure rather than people.

## Setup

```bash
export ENV=production                    # or: integration

cp env/production.env.example env/production.env && $EDITOR env/production.env
cp env/secrets.env.example     env/secrets.env     && $EDITOR env/secrets.env
rpai auth login

make preflight
make up            # safe to re-run after editing prompts or SQL
make verify        # expect: OK, DENIED, OK, DENIED, OK, DENIED
make smoke
```

`make verify` checks the database logins are separate. It distinguishes a
permission denial from a failed connection and exits non-zero on the latter.
Against a Postgres without TLS, use `PG_SSLMODE=disable`.

`make diff` shows what applying the manifests would change, without applying.

Run `make` with no arguments for the full target list. Other checks:
`make shortlist`, `make scores`, `make top-performer`, `make determinism`.

## Performance

| | |
|---|---|
| Shortlist | ~50s |
| Shortlist and ranking together | ~65-71s |
| A question needing no specialist | ~8s |
| `make prerun` — four questions concurrently | ~60–82s |

Around 96% of elapsed time is the model generating text. Tool calls account for
about 4%, and a database query through the agent takes ~0.6s. Within a turn,
elapsed time tracks output length at roughly 55 tokens per second; input size has
little effect.

Consequences:

- Shorter answers are faster. The prompts cap answer length for this reason.
- Fewer turns are faster. The prompts carry the exact column names, so the
   agents do not spend turns discovering the schema.
- Bounded questions are faster. "Rank 3 creators" takes ~90s; an open-ended
  "recommend some" exceeded 300s.
- Response compression (`MCP_RESPONSE_FORMAT_TOON`) reduces the payload but not
  the elapsed time, and it produces wrong figures — see known issues. It is off.

`make prerun` runs the questions ahead of time so answers are already available.
It prints a conversation ID per question; use those to locate them, as titles are
not always the question asked.

## Worth knowing

Two things that will catch you out, because neither produces an error.

- **Don't put a `$` in a `make ask` question.** `make` consumes `$5`, so
  `$5,000` arrives as `,000` and the agent infers a budget from the remainder.
  Write `5000 USD`. `make ask` warns if it spots this.
- **Identity comes from the credentials, not from a header.** Identity headers are
  stripped from traffic arriving from outside the cluster, so a policy aimed at
  someone else appears to do nothing. Sign a second identity into its own config
  (`RPAI_CONFIG=~/.rpai/contractor rpai auth login`) and pass `AS=contractor`.

The manifests and scripts carry a short comment at each place where a setting is
load-bearing — `config/manifests/creator-sql.yaml` explains why response
compression is off and why the row format is named objects, and
`config/sql/03-roles.sql` explains the database logins.

## Files

| | |
|---|---|
| `env/<env>.env` · `env/secrets.env` | Cluster details · database passwords (both gitignored) |
| `config/system-prompt.md` · `config/subagents/*.md` | Orchestrator · specialist instructions |
| `config/sql/01`–`07` | Tables, views, roles and grants, brands, hand-written creators, campaign history, generated creators |
| `config/manifests/*.yaml` | MCP servers and their data policies, applied with `rpai mcp apply` |
| `scripts/0[0-6]-*.sh` · `99-teardown.sh` | Build steps · teardown |
| `scripts/render-agent.sh` | Builds the agent manifest from the prompt files |
| `scripts/prerun.sh` · `gen-bulk-creators.py` | Pre-run questions · creator generator |

`config/sql/05-seed-showcase.sql` contains 14 hand-written creators, each
near-miss failing exactly one rule — 12,400 followers over the limit, $400 over
budget, a low safety score — so the exclusions are specific rather than generic.
