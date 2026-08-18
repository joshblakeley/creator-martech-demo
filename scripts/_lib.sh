# Shared helpers. Source from every step script.
#
# Conventions:
#   - Every script needs ENV=integration or ENV=production.
#   - Every step is safe to re-run.

set -euo pipefail

: "${ENV:?set ENV=integration or ENV=production}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="$ROOT/env/${ENV}.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "missing $ENV_FILE" >&2
  echo "run: cp env/${ENV}.env.example env/${ENV}.env && \$EDITOR env/${ENV}.env" >&2
  exit 1
fi
set -a; . "$ENV_FILE"; set +a

if [ -f "$ROOT/env/secrets.env" ]; then
  set -a; . "$ROOT/env/secrets.env"; set +a
fi

STATE_DIR="$ROOT/.state/$ENV"
mkdir -p "$STATE_DIR"

# --- logging --------------------------------------------------------------

c_blue=$'\033[34m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
log()  { printf "%s[%s]%s %s\n" "$c_blue" "$ENV" "$c_reset" "$*"; }
warn() { printf "%s[%s]%s %s\n" "$c_yellow" "$ENV" "$c_reset" "$*" >&2; }
ok()   { printf "%s[%s ✓]%s %s\n" "$c_green" "$ENV" "$c_reset" "$*"; }
die()  { printf "%s[%s ✗]%s %s\n" "$c_red" "$ENV" "$c_reset" "$*" >&2; exit 1; }

# --- auth -----------------------------------------------------------------

# Identity is selected by which rpai config file is in use, not by a profile
# flag. `AS=<name>` picks ~/.rpai/<name>; unset uses rpai's default config.
# Sign a second identity in with:
#   RPAI_CONFIG=~/.rpai/contractor rpai auth login
rpai_cfg() {
  [ -n "${AS:-}" ] && printf -- '-c %s/.rpai/%s' "$HOME" "$AS"
}

rpai_identity() {
  rpai $(rpai_cfg) auth status 2>/dev/null | awk '/user_email/{print $2; exit}'
}

# `rpai auth token` exits successfully and prints an EXPIRED token once the
# refresh has lapsed — the warning only goes to stderr. Checking the output is
# non-empty is therefore not enough: accept it and every later call fails with
# an unexplained 401. Check the expiry instead.
require_token() {
  local login_hint="rpai auth login"
  [ -n "${AS:-}" ] && login_hint="RPAI_CONFIG=$HOME/.rpai/$AS rpai auth login"

  TOKEN="$(rpai $(rpai_cfg) auth token 2>/dev/null || true)"
  [ -n "${TOKEN:-}" ] || die "no rpai token. Run: $login_hint"

  # Decode the JWT payload (base64url, no padding) and compare exp to now.
  local payload exp now
  payload="$(printf '%s' "$TOKEN" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in 2) payload="$payload==";; 3) payload="$payload=";; esac
  exp="$(printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null || true)"

  if [ -n "$exp" ]; then
    now="$(date +%s)"
    if [ "$exp" -le "$now" ]; then
      die "rpai token EXPIRED $(( (now - exp) / 3600 ))h ago (rpai exits 0 anyway). Run: $login_hint"
    fi
    # Warn before it lapses rather than mid-session.
    if [ "$exp" -le $(( now + 1800 )) ]; then
      warn "token expires in $(( (exp - now) / 60 ))m — refresh now: $login_hint"
    fi
  else
    warn "could not read exp claim from the rpai token; proceeding"
  fi

  export TOKEN
}

# Print the identity the current token actually carries. Identity comes from the
# token, not from a header — identity headers are stripped from outside traffic —
# so this is the only honest answer to "who is this running as". Worth showing
# rather than trusting which profile you think you picked.
token_identity() {
  local payload
  payload="$(printf '%s' "${TOKEN:-}" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null \
    | jq -r '.email // ."https://cloud.redpanda.com/email" // .sub // "unknown"' 2>/dev/null \
    || echo unknown
}

# --- HTTP -----------------------------------------------------------------

# Status-aware wrapper: dumps the response and exits non-zero on 4xx/5xx so
# `set -e` stops the calling script rather than letting a failed call write
# corrupt state.
_curl() {
  local method="$1" url="$2" body="${3:-}"
  local tmp; tmp="$(mktemp)"
  local args=(-sS -o "$tmp" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN")
  case "$method" in POST|PUT|PATCH) args+=(-H "Content-Type: application/json"); esac
  args+=(-H "Connect-Protocol-Version: 1")
  [ -n "$body" ] && args+=(--data "$body")
  local code; code="$(curl "${args[@]}" "$url")"
  case "$code" in
    2*) cat "$tmp"; rm -f "$tmp" ;;
    *)  printf 'HTTP %s on %s %s\n%s\n' "$code" "$method" "$url" "$(cat "$tmp")" >&2
        rm -f "$tmp"; return 1 ;;
  esac
}

# Connect-RPC against the ADP API — the same surface the Cloud UI uses.
adp_rpc() { _curl POST "$ADP_API_URL/$1" "$2"; }

dp_get()  { _curl GET    "$DATAPLANE_API$1"; }
dp_post() { _curl POST   "$DATAPLANE_API$1" "$2"; }
dp_put()  { _curl PUT    "$DATAPLANE_API$1" "$2"; }
dp_del()  { _curl DELETE "$DATAPLANE_API$1"; }

# --- postgres -------------------------------------------------------------

# psql as the owning role. PG_ADMIN_DSN is the owner DSN
# from env/secrets.env; the three least-privilege roles are created by
# config/sql/03-roles.sql and only ever used by the MCP servers.
pg() {
  command -v psql >/dev/null || die "psql not found (brew install libpq or postgresql)"
  psql "$PG_ADMIN_DSN" -v ON_ERROR_STOP=1 -q "$@"
}

pg_scalar() { pg -tAq -c "$1"; }

# --- misc -----------------------------------------------------------------

upper() { tr 'a-z' 'A-Z'; }
b64()   { printf '%s' "$1" | base64 | tr -d '\n'; }

# Refuse a policy that targets a group. Group targeting is not supported and
# does not degrade gracefully: the gateway refuses every call on a server
# carrying such a policy, including calls from people the policy never
# mentioned. Catching it here beats debugging it live.
assert_no_group_principals() {
  local payload="$1" label="${2:-payload}"
  if echo "$payload" | grep -q '"Group:'; then
    die "$label targets a group. That is not supported, and it stops every call on the whole MCP server — not just the group's. Target one person with \"User:<email>\"."
  fi
}
