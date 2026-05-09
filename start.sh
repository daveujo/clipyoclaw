#!/bin/bash
set -euo pipefail

umask 0077

# ── Config ─────────────────────────────────────────────────────────────
export DATABASE_URL="${DATABASE_URL:-postgres://postgres:paperclip@localhost:5432/paperclip}"
export PORT="${PORT:-3100}"
export SERVE_UI="${SERVE_UI:-true}"
export NODE_ENV="${NODE_ENV:-production}"
export HOST="${HOST:-0.0.0.0}"
export PAPERCLIP_HOME="${PAPERCLIP_HOME:-/paperclip}"
export PAPERCLIP_DEPLOYMENT_MODE="${PAPERCLIP_DEPLOYMENT_MODE:-authenticated}"
export PAPERCLIP_DEPLOYMENT_EXPOSURE="${PAPERCLIP_DEPLOYMENT_EXPOSURE:-private}"
export PAPERCLIP_INSTANCE_ID="${PAPERCLIP_INSTANCE_ID:-default}"
export PAPERCLIP_CONFIG="${PAPERCLIP_CONFIG:-${PAPERCLIP_HOME}/instances/default/config.json}"
export PAPERCLIP_TELEMETRY_DISABLED="${PAPERCLIP_TELEMETRY_DISABLED:-1}"
export DO_NOT_TRACK="${DO_NOT_TRACK:-1}"
export OPENCODE_ALLOW_ALL_MODELS="${OPENCODE_ALLOW_ALL_MODELS:-true}"
export SYNC_INTERVAL="${SYNC_INTERVAL:-3600}"
export SYNC_MAX_FILE_BYTES="${SYNC_MAX_FILE_BYTES:-52428800}"
export BACKUP_DATASET_NAME="${BACKUP_DATASET_NAME:-huggingclip-backup}"

# Derive public URL from HF Space host
if [ -z "${PAPERCLIP_PUBLIC_URL:-}" ] && [ -n "${SPACE_HOST:-}" ]; then
    export PAPERCLIP_PUBLIC_URL="https://${SPACE_HOST}"
fi

# Allowed hostnames
_ALLOWED="localhost,127.0.0.1,0.0.0.0"
if [ -n "${SPACE_HOST:-}" ]; then
    _ALLOWED="${_ALLOWED},${SPACE_HOST}"
fi
export PAPERCLIP_ALLOWED_HOSTNAMES="${PAPERCLIP_ALLOWED_HOSTNAMES:-${_ALLOWED}}"

# LLM API keys
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export OPENCODE_API_KEY="${OPENCODE_API_KEY:-}"
export OPENCODE_DISABLE_AUTOUPDATE="${OPENCODE_DISABLE_AUTOUPDATE:-1}"
OPENAI_API_KEY_USER_PROVIDED="${OPENAI_API_KEY}"
# NVIDIA (OpenAI-compatible) key support:
# - NVIDIA_API_KEY  : single key (backward-compatible)
# - NVIDIA_API_KEYS : single secret containing comma/newline-separated keys
export NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
export NVIDIA_API_KEYS="${NVIDIA_API_KEYS:-}"
# Optional NVIDIA provider registry JSON loaded at startup.
# Supports either a raw JSON blob or a path to a JSON file.
export NVIDIA_PROVIDER_JSON="${NVIDIA_PROVIDER_JSON:-}"
export NVIDIA_PROVIDER_JSON_FILE="${NVIDIA_PROVIDER_JSON_FILE:-}"
# Parses comma/newline-separated key material and returns newline-separated
# unique, trimmed keys. Empty entries are ignored.
parse_secret_list() {
    python3 - "$1" <<'PYEOF'
import sys

raw = sys.argv[1]
seen = set()
result = []

for part in raw.replace(",", "\n").splitlines():
    key = part.strip()
    if not key or key in seen:
        continue
    seen.add(key)
    result.append(key)

print("\n".join(result))
PYEOF
}
if [ -z "${NVIDIA_API_KEYS:-}" ] && [ -n "${NVIDIA_API_KEY:-}" ]; then
    NVIDIA_API_KEYS="${NVIDIA_API_KEY}"
fi
if [ -n "${NVIDIA_API_KEYS:-}" ]; then
    NVIDIA_API_KEYS_PARSED="$(parse_secret_list "${NVIDIA_API_KEYS}")"
    if [ -n "${NVIDIA_API_KEYS_PARSED}" ]; then
        NVIDIA_API_KEY="$(printf '%s\n' "${NVIDIA_API_KEYS_PARSED}" | head -n 1)"
        export NVIDIA_API_KEY
        _NVIDIA_KEY_INDEX=1
        while IFS= read -r _NVIDIA_KEY; do
            [ -z "${_NVIDIA_KEY}" ] && continue
            _NVIDIA_ENV_VAR="NVIDIA_API_KEY_${_NVIDIA_KEY_INDEX}"
            printf -v "${_NVIDIA_ENV_VAR}" '%s' "${_NVIDIA_KEY}"
            export "${_NVIDIA_ENV_VAR}"
            _NVIDIA_KEY_INDEX=$((_NVIDIA_KEY_INDEX + 1))
        done <<< "${NVIDIA_API_KEYS_PARSED}"
    fi
fi
if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${NVIDIA_API_KEY:-}" ]; then
    # Fallback for OpenAI-compatible clients.
    export OPENAI_API_KEY="${NVIDIA_API_KEY}"
fi
# Anthropic/Claude Code — set one or neither:
#   CLAUDE_CODE_OAUTH_TOKEN : long-lived OAuth token (sk-ant-oat01-..., 1 year)
#                             Generate at: claude.ai/settings → "Claude Code" → "Create token"
#   ANTHROPIC_API_KEY       : API key mode (sk-ant-api03-..., pay-per-use)
export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

mkdir -p "${PAPERCLIP_HOME}"

# Load NVIDIA provider registry once at startup if supplied.
# Keep the latest boot-time copy in a file Paperclip/child processes can read.
materialize_nvidia_provider_json() {
    if [ -n "${NVIDIA_PROVIDER_JSON_FILE:-}" ] && [ -f "${NVIDIA_PROVIDER_JSON_FILE}" ]; then
        NVIDIA_PROVIDER_JSON="$(cat "${NVIDIA_PROVIDER_JSON_FILE}")"
    fi
    if [ -n "${NVIDIA_PROVIDER_JSON:-}" ]; then
        NVIDIA_PROVIDER_JSON_FILE="${PAPERCLIP_HOME}/nvidia-provider.json"
        printf '%s' "${NVIDIA_PROVIDER_JSON}" > "${NVIDIA_PROVIDER_JSON_FILE}"
        chmod 600 "${NVIDIA_PROVIDER_JSON_FILE}"
        export PAPERCLIP_NVIDIA_PROVIDER_JSON_FILE="${NVIDIA_PROVIDER_JSON_FILE}"
    fi
}
materialize_nvidia_provider_json

configure_opencode_nvidia() {
    OPENCODE_NVIDIA_ENV_VARS="NVIDIA_API_KEY"
    if [ -n "${NVIDIA_API_KEYS_PARSED:-}" ]; then
        OPENCODE_NVIDIA_ENV_VARS="$(printf '%s\n' "${NVIDIA_API_KEYS_PARSED}" | nl -w1 -s '' -v1 | sed 's/^/NVIDIA_API_KEY_/' | paste -sd, -)"
        OPENCODE_NVIDIA_ENV_VARS="NVIDIA_API_KEY,${OPENCODE_NVIDIA_ENV_VARS}"
    fi
    export OPENCODE_NVIDIA_ENV_VARS
    export OPENCODE_CONFIG_CONTENT="$(python3 <<'PYEOF'
import json
import os

raw_config = (os.environ.get("OPENCODE_CONFIG_CONTENT") or "").strip()
try:
    config = json.loads(raw_config) if raw_config else {}
except Exception:
    config = {}
if not isinstance(config, dict):
    config = {}

provider = config.get("provider")
if not isinstance(provider, dict):
    provider = {}
    config["provider"] = provider

nvidia = provider.get("nvidia")
if not isinstance(nvidia, dict):
    nvidia = {}
    provider["nvidia"] = nvidia

env_vars = []
seen_env = set()
for part in (os.environ.get("OPENCODE_NVIDIA_ENV_VARS") or "").split(","):
    name = part.strip()
    if not name or name in seen_env:
        continue
    seen_env.add(name)
    env_vars.append(name)
if env_vars:
    existing_env = nvidia.get("env")
    merged_env = []
    seen_merged = set()
    if isinstance(existing_env, list):
        for item in existing_env:
            if isinstance(item, str) and item.strip() and item not in seen_merged:
                seen_merged.add(item)
                merged_env.append(item)
    for item in env_vars:
        if item not in seen_merged:
            seen_merged.add(item)
            merged_env.append(item)
    nvidia["env"] = merged_env

def extract_model_ids(value, out):
    if isinstance(value, dict):
        models = value.get("models")
        if isinstance(models, dict):
            for model_id in models.keys():
                if isinstance(model_id, str) and model_id.strip():
                    out.add(model_id.strip())
        elif isinstance(models, list):
            for item in models:
                if isinstance(item, str) and item.strip():
                    out.add(item.strip())
                elif isinstance(item, dict):
                    for key in ("id", "model"):
                        model_id = item.get(key)
                        if isinstance(model_id, str) and model_id.strip():
                            out.add(model_id.strip())
                            break
        for nested in value.values():
            extract_model_ids(nested, out)
    elif isinstance(value, list):
        for nested in value:
            extract_model_ids(nested, out)

nvidia_provider_json = ""
provider_file = (os.environ.get("PAPERCLIP_NVIDIA_PROVIDER_JSON_FILE") or "").strip()
if provider_file and os.path.isfile(provider_file):
    try:
        with open(provider_file, "r", encoding="utf-8") as f:
            nvidia_provider_json = f.read()
    except Exception:
        nvidia_provider_json = ""
if not nvidia_provider_json:
    nvidia_provider_json = (os.environ.get("NVIDIA_PROVIDER_JSON") or "").strip()

if nvidia_provider_json:
    try:
        provider_json = json.loads(nvidia_provider_json)
    except Exception:
        provider_json = None
    if provider_json is not None:
        model_ids = set()
        extract_model_ids(provider_json, model_ids)
        if model_ids and not nvidia.get("models"):
            nvidia["models"] = {model_id: {} for model_id in sorted(model_ids)}

print(json.dumps(config, separators=(",", ":")))
PYEOF
)"
}
if [ -n "${NVIDIA_API_KEY:-}" ] || [ -n "${NVIDIA_PROVIDER_JSON:-}" ] || [ -n "${NVIDIA_PROVIDER_JSON_FILE:-}" ] || [ -n "${PAPERCLIP_NVIDIA_PROVIDER_JSON_FILE:-}" ]; then
    configure_opencode_nvidia
fi

# Auth secrets (generate + persist so they survive restarts)
AUTH_SECRET_FILE="${PAPERCLIP_HOME}/.auth-secret"
if [ -z "${BETTER_AUTH_SECRET:-}" ]; then
    if [ -f "${AUTH_SECRET_FILE}" ]; then
        export BETTER_AUTH_SECRET=$(cat "${AUTH_SECRET_FILE}")
    else
        export BETTER_AUTH_SECRET=$(openssl rand -base64 32)
        echo "${BETTER_AUTH_SECRET}" > "${AUTH_SECRET_FILE}"
        chmod 600 "${AUTH_SECRET_FILE}"
    fi
fi

JWT_SECRET_FILE="${PAPERCLIP_HOME}/.jwt-secret"
if [ -z "${PAPERCLIP_AGENT_JWT_SECRET:-}" ]; then
    if [ -f "${JWT_SECRET_FILE}" ]; then
        export PAPERCLIP_AGENT_JWT_SECRET=$(cat "${JWT_SECRET_FILE}")
    else
        export PAPERCLIP_AGENT_JWT_SECRET=$(openssl rand -base64 32)
        echo "${PAPERCLIP_AGENT_JWT_SECRET}" > "${JWT_SECRET_FILE}"
        chmod 600 "${JWT_SECRET_FILE}"
    fi
fi

# ── Validate LLM providers ───────────────────────────────────────────────────
if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "⚠️  WARNING: No LLM provider configured"
    echo "   Set at least one of: GEMINI_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENCODE_API_KEY, NVIDIA_API_KEYS"
    echo "   Agents will fail to run without an LLM provider"
    echo ""
fi

# ── Banner ─────────────────────────────────────────────────────────────
echo ""
echo "  ╔════════════════════════════════════╗"
echo "  ║          HuggingClip               ║"
echo "  ╚════════════════════════════════════╝"
echo ""
echo "Public host  : ${SPACE_HOST:-not detected}"
echo "Public URL   : ${PAPERCLIP_PUBLIC_URL:-http://localhost:${PORT}}"
echo "App port     : ${PORT}"
echo "Deploy mode  : ${PAPERCLIP_DEPLOYMENT_MODE}"
echo "Sync every   : ${SYNC_INTERVAL}s"
echo ""

# ── PostgreSQL ──────────────────────────────────────────────────────────────
PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | sort -V | tail -1)
if [ -z "$PG_VERSION" ]; then
    echo "ERROR: PostgreSQL not found"
    exit 1
fi
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

if [ ! -f "${PG_DATA}/PG_VERSION" ]; then
    echo "Initializing PostgreSQL cluster..."
    pg_createcluster "${PG_VERSION}" main --locale=C.UTF-8 >/dev/null 2>&1
fi

if ! pg_ctlcluster "${PG_VERSION}" main status 2>/dev/null | grep -q "online"; then
    echo "Starting PostgreSQL..."
    pg_ctlcluster "${PG_VERSION}" main start >/dev/null 2>&1
fi

until pg_isready -h localhost -U postgres >/dev/null 2>&1; do
    sleep 1
done

# Generate random DB password on first run (don't hardcode 'paperclip')
DB_PASSWORD_FILE="${PAPERCLIP_HOME}/.db-password"
if [ ! -f "${DB_PASSWORD_FILE}" ]; then
    DB_PASSWORD=$(openssl rand -hex 24)
    echo "$DB_PASSWORD" > "${DB_PASSWORD_FILE}"
    chmod 600 "${DB_PASSWORD_FILE}"
else
    DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")
fi
export PGPASSWORD="${DB_PASSWORD}"

su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';\"" >/dev/null 2>&1 || true
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname = 'paperclip'\" | grep -q 1 || psql -c \"CREATE DATABASE paperclip OWNER postgres;\"" >/dev/null 2>&1 || true

# Update DATABASE_URL with generated password (if not explicitly set)
# URL-encode the password to handle special chars (e.g. / + = from old base64 passwords)
if [[ "$DATABASE_URL" == *"postgres:paperclip"* ]]; then
    DB_PASSWORD_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${DB_PASSWORD}")
    export DATABASE_URL="postgres://postgres:${DB_PASSWORD_ENCODED}@localhost:5432/paperclip"
fi

echo "PostgreSQL ready (v${PG_VERSION})"

# ── Restore from HF Dataset ───────────────────────────────────────────────────
SYNC_STATUS_FILE="/tmp/sync-status.json"
if [ -n "${HF_TOKEN:-}" ]; then
    echo "Restoring persisted data from HF Dataset..."
    python3 /app/paperclip-sync.py restore 2>&1 || true

    # Re-stamp .db-password with current session's password so restore can't
    # overwrite it with an old base64 value that breaks DATABASE_URL next restart
    echo "${DB_PASSWORD}" > "${DB_PASSWORD_FILE}"
    chmod 600 "${DB_PASSWORD_FILE}"

    # Update PostgreSQL password to match (restore may have re-created the DB)
    su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';\"" >/dev/null 2>&1 || true

    # Check if last sync failed
    if [ -f "${SYNC_STATUS_FILE}" ]; then
        LAST_ERROR=$(python3 -c "import json; f=open('${SYNC_STATUS_FILE}'); d=json.load(f); print(d.get('last_error') or '')" 2>/dev/null || true)
        if [ -n "$LAST_ERROR" ]; then
            echo "⚠️  WARNING: Last backup sync failed: $LAST_ERROR"
            echo "   Data may not be persisted to HF Dataset"
        fi
    fi
else
    echo "HF_TOKEN not set — running without backup persistence"
fi

# Re-materialize NVIDIA provider registry after restore so backups cannot overwrite it.
materialize_nvidia_provider_json
if [ -n "${NVIDIA_API_KEY:-}" ] || [ -n "${NVIDIA_PROVIDER_JSON:-}" ] || [ -n "${NVIDIA_PROVIDER_JSON_FILE:-}" ] || [ -n "${PAPERCLIP_NVIDIA_PROVIDER_JSON_FILE:-}" ]; then
    configure_opencode_nvidia
fi

# ── Cloudflare Proxy ──────────────────────────────────────────────────────────
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
    echo "Setting up Cloudflare proxy..."
    python3 /app/cloudflare-proxy-setup.py 2>&1 || echo "Cloudflare setup failed, continuing without proxy"
fi

# Source CF proxy env if the setup script wrote it (provides CLOUDFLARE_PROXY_URL + SECRET)
_CF_ENV="/tmp/huggingclaw-cloudflare-proxy.env"
if [ -f "${_CF_ENV}" ]; then
    # shellcheck source=/dev/null
    . "${_CF_ENV}"
fi

# ── Cloudflare proxy flag (applied inline to Paperclip only, not exported globally)
# Only enable if proxy is actually configured. Otherwise agent CLIs (claude, gemini,
# codex) inherit it via subprocess env and break their HTTP requests.
_CF_NODE_OPTS=""
if [ -n "${CLOUDFLARE_PROXY_URL:-}" ] && [ -f /app/cloudflare-proxy.js ]; then
    _CF_NODE_OPTS="--require /app/cloudflare-proxy.js"
fi

# ── Gemini CLI environment ───────────────────────────────────────────────────
# Disable sandbox (would try to start Docker inside Docker)
export GEMINI_SANDBOX=false
# Trust the workspace — paperclip user runs from /app/paperclip (root-owned).
export GEMINI_CLI_TRUST_WORKSPACE=true
# Kill-switch for relaunch.ts::relaunchAppInChildProcess() — the spawn inside
# fails when Paperclip pipes gemini's stdio (IPC channel setup fails).
# With this set, relaunchAppInChildProcess() returns early and gemini runs
# as the main process without spawning a child.
export GEMINI_CLI_NO_RELAUNCH=1

# ── Background sync loop ──────────────────────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
    (
        while true; do
            sleep "$SYNC_INTERVAL"
            python3 /app/paperclip-sync.py sync 2>&1 || true
        done
    ) &
    SYNC_PID=$!
else
    SYNC_PID=""
fi

# ── Health server ─────────────────────────────────────────────────────────────
node /app/health-server.js &
HEALTH_PID=$!

if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
  echo "Setting up Cloudflare KeepAlive monitor..."
  python3 /app/cloudflare-keepalive-setup.py || true
fi

sleep 2

# ── Paperclip instance config ─────────────────────────────────────────────────
cd /app/paperclip

if [ ! -d "node_modules" ]; then
    echo "Installing Paperclip dependencies..."
    pnpm install 2>&1 | tail -5 || npm install 2>&1 | tail -5
fi

if [ ! -f "${PAPERCLIP_CONFIG}" ]; then
    echo "Creating instance config (first boot)..."
    mkdir -p "$(dirname "${PAPERCLIP_CONFIG}")"
    python3 <<'PYEOF'
import json, os

home = os.environ.get("PAPERCLIP_HOME", "/paperclip")
port = int(os.environ.get("PORT", "3100"))
public_url = os.environ.get("PAPERCLIP_PUBLIC_URL", f"http://localhost:{port}")
allowed_raw = os.environ.get("PAPERCLIP_ALLOWED_HOSTNAMES", "")
allowed_hostnames = []
seen = set()
for part in allowed_raw.split(","):
    host = part.strip()
    if not host or host in seen:
        continue
    seen.add(host)
    allowed_hostnames.append(host)

config = {
    "$meta": {"version": 1, "updatedAt": "2024-01-01T00:00:00Z", "source": "onboard"},
    "llm": {"provider": "claude", "apiKey": ""},
    "database": {
        "mode": "postgres",
        "connectionString": os.environ.get("DATABASE_URL", "postgres://postgres:paperclip@localhost:5432/paperclip")
    },
    "logging": {"mode": "file", "logDir": f"{home}/instances/default/logs"},
    "server": {
        "deploymentMode": os.environ.get("PAPERCLIP_DEPLOYMENT_MODE", "authenticated"),
        "exposure": os.environ.get("PAPERCLIP_DEPLOYMENT_EXPOSURE", "private"),
        "host": "0.0.0.0",
        "port": port,
        "allowedHostnames": allowed_hostnames,
        "serveUi": True
    },
    "auth": {
        "baseUrlMode": "explicit",
        "publicBaseUrl": public_url,
        "disableSignUp": False
    },
    "storage": {
        "provider": "local_disk",
        "localDisk": {"baseDir": f"{home}/instances/default/data/storage"}
    },
    "secrets": {
        "provider": "local_encrypted",
        "strictMode": False,
        "localEncrypted": {"keyFilePath": f"{home}/instances/default/secrets/master.key"}
    },
    "telemetry": {"enabled": False}
}

config_path = os.environ.get("PAPERCLIP_CONFIG", f"{home}/instances/default/config.json")
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"  Config written to {config_path}")
PYEOF
fi

# Keep auth/public URL + allowed hostnames aligned on every boot (including restores)
if [ -f "${PAPERCLIP_CONFIG}" ]; then
    python3 <<'PYEOF'
import json, os

config_path = os.environ.get("PAPERCLIP_CONFIG", "")
public_url = os.environ.get("PAPERCLIP_PUBLIC_URL", "").strip()
allowed_raw = os.environ.get("PAPERCLIP_ALLOWED_HOSTNAMES", "")

if not config_path or not os.path.exists(config_path):
    raise SystemExit(0)

with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

changed = False

if public_url:
    auth = config.setdefault("auth", {})
    if auth.get("baseUrlMode") != "explicit":
        auth["baseUrlMode"] = "explicit"
        changed = True
    if auth.get("publicBaseUrl") != public_url:
        auth["publicBaseUrl"] = public_url
        changed = True

desired_hostnames = []
seen = set()
for part in allowed_raw.split(","):
    host = part.strip()
    if not host or host in seen:
        continue
    seen.add(host)
    desired_hostnames.append(host)

if desired_hostnames:
    server = config.setdefault("server", {})
    if server.get("allowedHostnames") != desired_hostnames:
        server["allowedHostnames"] = desired_hostnames
        changed = True

if changed:
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
PYEOF
fi

# ── Graceful shutdown ─────────────────────────────────────────────────────────
cleanup() {
    echo "Shutting down — syncing data..."

    # Stop services
    [ -n "${HEALTH_PID:-}" ]    && kill "$HEALTH_PID"    2>/dev/null || true
    [ -n "${PAPERCLIP_PID:-}" ] && kill "$PAPERCLIP_PID" 2>/dev/null || true

    # Kill background sync loop, then wait for it to exit before running final sync
    # (avoids concurrent writes: kill stops the loop, wait confirms it's done)
    if [ -n "${SYNC_PID:-}" ]; then
        kill "$SYNC_PID" 2>/dev/null || true
        wait "$SYNC_PID" 2>/dev/null || true
    fi

    # Run final backup sync
    if [ -n "${HF_TOKEN:-}" ]; then
        python3 /app/paperclip-sync.py sync 2>&1 || true
    fi

    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Codex API key config ─────────────────────────────────────────────────────
# forced_login_method="api" alone isn't enough — codex reads the key from its
# credentials store, not from OPENAI_API_KEY env var (which Paperclip may not
# pass to subprocesses). Workaround: custom provider with experimental_bearer_token
# baked in. Can't use [model_providers.openai] — reserved built-in ID.
if [ -n "${OPENAI_API_KEY:-}" ]; then
    CODEX_PROVIDER_ID="openai-hf"
    CODEX_PROVIDER_NAME="OpenAI"
    CODEX_PROVIDER_BASE_URL="https://api.openai.com/v1"
    if [ -z "${OPENAI_API_KEY_USER_PROVIDED:-}" ] && [ -n "${NVIDIA_API_KEY:-}" ]; then
        CODEX_PROVIDER_ID="nvidia-hf"
        CODEX_PROVIDER_NAME="NVIDIA"
        CODEX_PROVIDER_BASE_URL="https://integrate.api.nvidia.com/v1"
    fi
    mkdir -p /home/paperclip/.codex
    cat > /home/paperclip/.codex/config.toml <<TOMLEOF
forced_login_method = "api"
model_provider = "${CODEX_PROVIDER_ID}"

[model_providers.${CODEX_PROVIDER_ID}]
name = "${CODEX_PROVIDER_NAME}"
base_url = "${CODEX_PROVIDER_BASE_URL}"
experimental_bearer_token = "${OPENAI_API_KEY}"
requires_openai_auth = false
TOMLEOF
    chmod 600 /home/paperclip/.codex/config.toml
    chown -R paperclip:paperclip /home/paperclip/.codex
fi

# ── Ensure paperclip user owns runtime dirs ──────────────────────────────────
chown -R paperclip:paperclip /app /paperclip 2>/dev/null || true

# ── Launch Paperclip as non-root ──────────────────────────────────────────────
# Agent CLIs (claude, gemini, codex) refuse --dangerously-skip-permissions as root.
# Run Paperclip as 'paperclip' user so all spawned subprocesses are non-root.
echo "Starting Paperclip..."
HOME=/home/paperclip NODE_OPTIONS="${_CF_NODE_OPTS}" runuser -u paperclip -- \
    node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js &
PAPERCLIP_PID=$!

# Wait for API ready (max 90s)
PAPERCLIP_READY=false
for i in $(seq 1 45); do
    if curl -sf http://127.0.0.1:3100/api/health >/dev/null 2>&1; then
        echo "Paperclip ready (${i}s)"
        PAPERCLIP_READY=true
        break
    fi
    sleep 2
done

if [ "$PAPERCLIP_READY" = true ]; then
    BOOTSTRAP_OUTPUT=$(HOME=/home/paperclip runuser -u paperclip -- pnpm paperclipai auth bootstrap-ceo 2>&1 || true)
    INVITE_URL=$(echo "$BOOTSTRAP_OUTPUT" | grep "Invite URL:" 2>/dev/null | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | grep -o 'https\?://[^ ]*' | head -1 || true)
    if [ -n "$INVITE_URL" ] && [ -n "${PAPERCLIP_PUBLIC_URL:-}" ]; then
INVITE_URL=$(python3 - "${INVITE_URL}" "${PAPERCLIP_PUBLIC_URL}" <<'PYEOF'
import sys
from urllib.parse import urlparse, urlunparse

invite_url = (sys.argv[1] or "").strip()
public_base = (sys.argv[2] or "").strip()

try:
    invite = urlparse(invite_url)
    base = urlparse(public_base)
    if invite.scheme and invite.netloc and base.scheme and base.netloc:
        path = invite.path or "/"
        if path == "/invite" or path.startswith("/invite/"):
            path = f"/app{path}"
        print(urlunparse((base.scheme, base.netloc, path, invite.params, invite.query, invite.fragment)))
    else:
        print(invite_url)
except Exception:
    print(invite_url)
PYEOF
)
    fi
    if [ -n "$INVITE_URL" ]; then
        echo "$INVITE_URL" > /tmp/invite-url.txt
        echo ""
        echo "  ┌─────────────────────────────────────────────────────┐"
        echo "  │  ADMIN SETUP — open this URL in your browser:       │"
        echo "  │                                                     │"
        echo "  │  ${INVITE_URL}"
        echo "  │                                                     │"
        echo "  └─────────────────────────────────────────────────────┘"
        echo ""
    else
        rm -f /tmp/invite-url.txt
        echo "Admin account already configured"
    fi

else
    echo "Warning: Paperclip did not become ready in 90s"
fi

echo "HuggingClip is ready!"
echo ""
echo "  Health dashboard : http://localhost:7861/"
echo "  Paperclip UI     : http://localhost:7861/app/"
echo "  API              : http://localhost:7861/api/"
echo ""

wait $PAPERCLIP_PID
