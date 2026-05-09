#!/bin/bash
set -euo pipefail

umask 0077

# ── Config ────────────────────────────────────────────────────────────
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
export OPENCODE_API_KEY="${OPENCODE_API_KEY:-}"
export NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
export NVIDIA_API_KEYS="${NVIDIA_API_KEYS:-}"
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

nvidia["experimental_bearer_token"] = os.environ.get("OPENAI_API_KEY") or ""

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

echo "Starting Paperclip..."
